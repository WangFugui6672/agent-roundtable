from __future__ import annotations

import uuid
from urllib.parse import urlsplit

from django.utils import timezone
from rest_framework import serializers

from apps.roundtables.message_validation import validate_agent_message
from apps.roundtables.models import (
    AgentProfile,
    Message,
    MessageReport,
    RoundSummary,
    Roundtable,
    RoundtableAgent,
    Turn,
)
from apps.roundtables.protocol import (
    BODY_HARD_MAX_CHARS,
    CLAIM_MAX_CHARS,
    DEFAULT_CONFIDENCE,
    FAILURE_CODES,
    MAX_REFERENCES,
    SUMMARY_MAX_ITEMS_PER_SECTION,
    SUMMARY_MAX_REFERENCES_PER_ITEM,
    SUMMARY_TEXT_MAX_CHARS,
    iso8601_millis,
)

MVP_AGENT_COUNT = 3

#: Keys that must never reach the backend. The API key lives in the iOS
#: Keychain (ADR 0001), so a request carrying one is rejected instead of
#: silently ignored: a silent drop would hide a client bug that leaks the key.
SECRET_FIELD_NAMES = frozenset({"api_key", "apikey", "api-key", "provider_api_key"})


def contains_secret(data: object) -> bool:
    """Recursively look for API-key-shaped fields anywhere in the request body."""
    if isinstance(data, dict):
        for key, value in data.items():
            if str(key).lower() in SECRET_FIELD_NAMES or contains_secret(value):
                return True
    elif isinstance(data, (list, tuple)):
        return any(contains_secret(item) for item in data)
    return False


class UsageInputSerializer(serializers.Serializer):
    input_tokens = serializers.IntegerField(
        min_value=0, max_value=1_000_000, allow_null=True, required=False
    )
    output_tokens = serializers.IntegerField(
        min_value=0, max_value=1_000_000, allow_null=True, required=False
    )
    latency_ms = serializers.IntegerField(
        min_value=0, max_value=600_000, allow_null=True, required=False
    )
    retry_count = serializers.IntegerField(min_value=0, max_value=10, default=0)


class AgentProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = AgentProfile
        fields = [
            "id",
            "key",
            "name",
            "tagline",
            "expertise",
            "goal",
            "default_stance",
            "style",
            "banned_behaviors",
            "max_reply_chars",
        ]
        read_only_fields = fields


class ParticipantSerializer(serializers.ModelSerializer):
    agent = AgentProfileSerializer(source="agent_profile", read_only=True)

    class Meta:
        model = RoundtableAgent
        fields = ["id", "position", "state", "agent"]
        read_only_fields = fields


class BudgetSerializer(serializers.Serializer):
    max_rounds = serializers.IntegerField()
    max_agent_messages = serializers.IntegerField()
    agent_messages_used = serializers.SerializerMethodField()
    max_reported_tokens = serializers.IntegerField()
    reported_tokens = serializers.IntegerField()
    max_duration_seconds = serializers.IntegerField()
    started_at = serializers.SerializerMethodField()
    elapsed_seconds = serializers.SerializerMethodField()
    exhausted_reason = serializers.CharField(source="budget_exhausted_reason")
    token_source = serializers.SerializerMethodField()

    def get_agent_messages_used(self, obj: Roundtable) -> int:
        return obj.messages.filter(author_type=Message.AuthorType.AGENT).count()

    def get_started_at(self, obj: Roundtable) -> str | None:
        return iso8601_millis(obj.started_at) if obj.started_at else None

    def get_elapsed_seconds(self, obj: Roundtable) -> int:
        if obj.started_at is None:
            return 0
        return max(0, int((timezone.now() - obj.started_at).total_seconds()))

    def get_token_source(self, obj: Roundtable) -> str:
        return "client_reported"


class TurnSerializer(serializers.ModelSerializer):
    turn_id = serializers.UUIDField(source="id", read_only=True)
    round = serializers.IntegerField(source="round_number", read_only=True)
    roundtable_agent_id = serializers.UUIDField(source="roundtable_agent.id", read_only=True)
    position = serializers.IntegerField(source="roundtable_agent.position", read_only=True)
    agent_key = serializers.CharField(source="roundtable_agent.agent_profile.key", read_only=True)
    agent_name = serializers.CharField(source="roundtable_agent.agent_profile.name", read_only=True)

    class Meta:
        model = Turn
        fields = [
            "turn_id",
            "round",
            "roundtable_agent_id",
            "position",
            "agent_key",
            "agent_name",
        ]
        read_only_fields = fields


class ProviderMetadataSerializer(serializers.Serializer):
    """Non-secret provider snapshot (GLOSSARY: Provider 配置).

    The backend stores it for display and future observability only. It never
    dials the provider and never sees the API key.
    """

    kind = serializers.ChoiceField(choices=Roundtable.ProviderKind.choices)
    base_url = serializers.CharField(max_length=300, trim_whitespace=True)
    model = serializers.CharField(max_length=120, trim_whitespace=True)

    def validate_base_url(self, value: str) -> str:
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise serializers.ValidationError("BaseURL 必须是 http 或 https 地址。")
        if parsed.query or parsed.fragment:
            raise serializers.ValidationError("BaseURL 不能包含查询参数或片段。")
        return value.rstrip("/")


class RoundtableSerializer(serializers.ModelSerializer):
    participants = ParticipantSerializer(source="agents", many=True, read_only=True)
    last_sequence = serializers.IntegerField(source="event_sequence", read_only=True)
    provider = serializers.SerializerMethodField()
    budget = serializers.SerializerMethodField()
    active_turn = serializers.SerializerMethodField()
    follow_up_context = serializers.SerializerMethodField()
    created_at = serializers.SerializerMethodField()
    updated_at = serializers.SerializerMethodField()

    class Meta:
        model = Roundtable
        fields = [
            "id",
            "topic",
            "status",
            "mode",
            "max_rounds",
            "current_round",
            "last_sequence",
            "pause_pending",
            "active_turn",
            "provider",
            "parent_roundtable_id",
            "source_summary_id",
            "follow_up_context",
            "budget",
            "created_at",
            "updated_at",
            "participants",
        ]
        read_only_fields = fields

    def get_provider(self, obj: Roundtable) -> dict[str, str] | None:
        if not obj.provider_kind:
            return None
        return {
            "kind": obj.provider_kind,
            "base_url": obj.provider_base_url,
            "model": obj.provider_model,
        }

    def get_budget(self, obj: Roundtable) -> dict:
        return BudgetSerializer(obj).data

    def get_active_turn(self, obj: Roundtable) -> dict | None:
        turn = (
            Turn.objects.filter(roundtable=obj, status=Turn.Status.PENDING)
            .select_related("roundtable_agent__agent_profile")
            .first()
        )
        if turn is None:
            return None
        return TurnSerializer(turn).data

    def get_follow_up_context(self, obj: Roundtable) -> dict | None:
        if obj.parent_roundtable_id is None or obj.source_summary_id is None:
            return None
        parent = obj.parent_roundtable
        summary = obj.source_summary
        if parent is None or summary is None:
            return None
        return {
            "parent_topic": parent.topic,
            "summary": RoundSummarySerializer(summary).data,
        }

    def get_created_at(self, obj: Roundtable) -> str:
        return iso8601_millis(obj.created_at)

    def get_updated_at(self, obj: Roundtable) -> str:
        return iso8601_millis(obj.updated_at)


class RoundtableCreateSerializer(serializers.Serializer):
    """Request body of ``POST /api/v1/roundtables/``."""

    topic = serializers.CharField(max_length=500, trim_whitespace=True)
    agent_profile_ids = serializers.ListField(
        child=serializers.UUIDField(),
        min_length=MVP_AGENT_COUNT,
        max_length=MVP_AGENT_COUNT,
        allow_empty=False,
    )
    provider = ProviderMetadataSerializer(required=False, allow_null=True)

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            # List-shaped detail keeps `error.details` uniform with the other
            # field errors (docs/protocol.md 2.5) and is asserted by tests.
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs

    def validate_agent_profile_ids(self, value: list) -> list:
        if len(set(value)) != MVP_AGENT_COUNT:
            raise serializers.ValidationError("必须选择 3 个不同的 Agent。")
        found = AgentProfile.objects.filter(id__in=value).count()
        if found != MVP_AGENT_COUNT:
            raise serializers.ValidationError("Agent 不存在。")
        return value


class FollowUpCreateSerializer(serializers.Serializer):
    topic = serializers.CharField(max_length=500, trim_whitespace=True)

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs


class SummaryItemSerializer(serializers.Serializer):
    text = serializers.CharField(
        max_length=SUMMARY_TEXT_MAX_CHARS,
        trim_whitespace=True,
        allow_blank=False,
    )
    reference_message_ids = serializers.ListField(
        child=serializers.UUIDField(),
        min_length=1,
        max_length=SUMMARY_MAX_REFERENCES_PER_ITEM,
        allow_empty=False,
    )

    def validate_reference_message_ids(self, value: list[uuid.UUID]) -> list[uuid.UUID]:
        if len(set(value)) != len(value):
            raise serializers.ValidationError("同一结论项不能重复引用同一条观点。")
        return value


class RoundSummaryCreateSerializer(serializers.Serializer):
    expected_version = serializers.IntegerField(min_value=0)
    degraded = serializers.BooleanField()
    consensus = SummaryItemSerializer(
        many=True,
        max_length=SUMMARY_MAX_ITEMS_PER_SECTION,
        required=True,
    )
    dissent = SummaryItemSerializer(
        many=True,
        max_length=SUMMARY_MAX_ITEMS_PER_SECTION,
        required=True,
    )
    recommendations = SummaryItemSerializer(
        many=True,
        max_length=SUMMARY_MAX_ITEMS_PER_SECTION,
        required=True,
    )
    unresolved = SummaryItemSerializer(
        many=True,
        max_length=SUMMARY_MAX_ITEMS_PER_SECTION,
        required=True,
    )

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs


class RoundSummarySerializer(serializers.ModelSerializer):
    created_at = serializers.SerializerMethodField()
    updated_at = serializers.SerializerMethodField()

    class Meta:
        model = RoundSummary
        fields = [
            "id",
            "version",
            "degraded",
            "consensus",
            "dissent",
            "recommendations",
            "unresolved",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_created_at(self, obj: RoundSummary) -> str:
        return iso8601_millis(obj.created_at)

    def get_updated_at(self, obj: RoundSummary) -> str:
        return iso8601_millis(obj.updated_at)


class MessageSerializer(serializers.ModelSerializer):
    """Wire shape of one persisted utterance (docs/protocol.md 3.4 ``Message``)."""

    author = serializers.SerializerMethodField()
    references = serializers.SerializerMethodField()
    created_at = serializers.SerializerMethodField()
    stance = serializers.SerializerMethodField()
    claim = serializers.SerializerMethodField()
    confidence = serializers.SerializerMethodField()
    mentioned_agent_ids = serializers.SerializerMethodField()
    challenge_target_agent_id = serializers.SerializerMethodField()
    turn_id = serializers.UUIDField(source="turn.id", allow_null=True, read_only=True)
    supersedes_message_id = serializers.UUIDField(
        source="supersedes_id",
        allow_null=True,
        read_only=True,
    )
    superseded_by_message_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = Message
        fields = [
            "id",
            "turn_id",
            "round_number",
            "author",
            "message_type",
            "claim",
            "body",
            "stance",
            "references",
            "challenge_target_agent_id",
            "confidence",
            "mentioned_agent_ids",
            "is_key_point",
            "supersedes_message_id",
            "superseded_by_message_id",
            "created_at",
        ]
        read_only_fields = fields

    def get_author(self, obj: Message) -> dict[str, str]:
        if obj.author_type == Message.AuthorType.USER:
            return {"type": "user", "name": "用户"}
        if obj.roundtable_agent is None:
            raise ValueError("Agent messages require a RoundtableAgent.")
        agent = obj.roundtable_agent
        return {
            "type": "agent",
            "roundtable_agent_id": str(agent.id),
            "agent_key": agent.agent_profile.key,
            "name": agent.agent_profile.name,
        }

    def get_references(self, obj: Message) -> list[str]:
        return [str(reference.id) for reference in obj.references.all()]

    def get_challenge_target_agent_id(self, obj: Message) -> str | None:
        if obj.challenge_target_id is None:
            return None
        return str(obj.challenge_target_id)

    def get_stance(self, obj: Message) -> str | None:
        return obj.stance or None

    def get_claim(self, obj: Message) -> str | None:
        return obj.claim or None

    def get_confidence(self, obj: Message) -> float | None:
        return obj.confidence

    def get_mentioned_agent_ids(self, obj: Message) -> list[str]:
        return obj.mentioned_agent_ids

    def get_created_at(self, obj: Message) -> str:
        return iso8601_millis(obj.created_at)


class UserMessageCreateSerializer(serializers.Serializer):
    """Request body of ``POST /api/v1/roundtables/{id}/user-messages``."""

    body = serializers.CharField(
        max_length=BODY_HARD_MAX_CHARS,
        trim_whitespace=True,
        allow_blank=False,
    )
    mentioned_agent_ids = serializers.ListField(
        child=serializers.UUIDField(),
        required=False,
        max_length=MVP_AGENT_COUNT,
        default=list,
    )

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})

        mentioned_ids = attrs.get("mentioned_agent_ids") or []
        if len(set(mentioned_ids)) != len(mentioned_ids):
            raise serializers.ValidationError({"mentioned_agent_ids": "被点名的 Agent 不能重复。"})

        roundtable: Roundtable = self.context["roundtable"]
        found = RoundtableAgent.objects.filter(id__in=mentioned_ids, roundtable=roundtable).count()
        if found != len(mentioned_ids):
            raise serializers.ValidationError(
                {"mentioned_agent_ids": "被点名的 Agent 不存在或不属于此圆桌。"}
            )
        return attrs


class MessageReportCreateSerializer(serializers.Serializer):
    reason = serializers.ChoiceField(choices=MessageReport.Reason.choices)
    details = serializers.CharField(
        max_length=500,
        trim_whitespace=True,
        required=False,
        allow_blank=True,
        default="",
    )

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs


class MessageReportSerializer(serializers.ModelSerializer):
    message_id = serializers.UUIDField(read_only=True)
    created_at = serializers.SerializerMethodField()
    updated_at = serializers.SerializerMethodField()

    class Meta:
        model = MessageReport
        fields = [
            "id",
            "message_id",
            "reason",
            "details",
            "state",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_created_at(self, obj: MessageReport) -> str:
        return iso8601_millis(obj.created_at)

    def get_updated_at(self, obj: MessageReport) -> str:
        return iso8601_millis(obj.updated_at)


class MessageCreateSerializer(serializers.Serializer):
    """Request body of ``POST /api/v1/roundtables/{id}/messages``.

    Validation mirrors PRD 7.7: type, claim, body length, stance, references
    and confidence. ``max_reply_chars`` comes from the agent's profile so the
    client and the server agree on the cap.
    """

    turn_id = serializers.UUIDField()
    roundtable_agent_id = serializers.UUIDField()
    message_type = serializers.ChoiceField(choices=Message.Type.choices)
    claim = serializers.CharField(max_length=CLAIM_MAX_CHARS, trim_whitespace=True)
    body = serializers.CharField(
        max_length=BODY_HARD_MAX_CHARS,
        trim_whitespace=True,
        required=False,
        allow_blank=True,
        default="",
    )
    stance = serializers.ChoiceField(
        choices=Message.Stance.choices, required=False, allow_null=True, allow_blank=True
    )
    references = serializers.ListField(
        child=serializers.UUIDField(), required=False, max_length=MAX_REFERENCES, default=list
    )
    challenge_target_agent_id = serializers.UUIDField(required=False, allow_null=True)
    confidence = serializers.FloatField(
        min_value=0, max_value=1, required=False, default=DEFAULT_CONFIDENCE
    )
    usage = UsageInputSerializer(required=False, allow_null=True)

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            # List-shaped detail keeps `error.details` uniform with the other
            # field errors (docs/protocol.md 2.5) and is asserted by tests.
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})

        roundtable: Roundtable = self.context["roundtable"]
        agent = (
            RoundtableAgent.objects.filter(id=attrs["roundtable_agent_id"], roundtable=roundtable)
            .select_related("agent_profile")
            .first()
        )
        if agent is None:
            raise serializers.ValidationError({"roundtable_agent_id": "该 Agent 不属于此圆桌。"})
        attrs["agent"] = agent

        if attrs["message_type"] == Message.Type.PASS:
            raise serializers.ValidationError(
                {"message_type": "沉默必须通过 turns/pass 提交，不能作为普通发言。"}
            )
        if attrs["message_type"] == Message.Type.USER_MESSAGE:
            raise serializers.ValidationError(
                {"message_type": "用户消息必须通过 user-messages 提交，不能伪装成 Agent 发言。"}
            )

        body = attrs.get("body", "")
        limit = agent.agent_profile.max_reply_chars
        if len(body) > limit:
            raise serializers.ValidationError({"body": f"正文超过 {limit} 字上限。"})
        if not body:
            raise serializers.ValidationError({"body": "正文不能为空。"})

        references = attrs.get("references") or []
        if len(set(references)) != len(references):
            raise serializers.ValidationError({"references": "引用消息不能重复。"})
        turn = Turn.objects.filter(
            id=attrs["turn_id"],
            roundtable=roundtable,
            status=Turn.Status.PENDING,
        ).first()
        if turn is not None:
            validate_agent_message(
                roundtable=roundtable,
                agent=agent,
                turn=turn,
                data=attrs,
            )
        if references:
            found = Message.objects.filter(id__in=references, roundtable=roundtable).count()
            if found != len(references):
                raise serializers.ValidationError(
                    {"references": "引用的消息不存在或不属于此圆桌。"}
                )
        return attrs


class TurnPassSerializer(serializers.Serializer):
    turn_id = serializers.UUIDField()
    roundtable_agent_id = serializers.UUIDField()
    usage = UsageInputSerializer(required=False, allow_null=True)

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs


class TurnFailSerializer(serializers.Serializer):
    turn_id = serializers.UUIDField()
    roundtable_agent_id = serializers.UUIDField()
    failure_code = serializers.ChoiceField(choices=sorted(FAILURE_CODES))
    message = serializers.CharField(max_length=500, trim_whitespace=True, allow_blank=False)
    retryable = serializers.BooleanField()
    partial = serializers.CharField(
        max_length=BODY_HARD_MAX_CHARS,
        trim_whitespace=True,
        required=False,
        allow_blank=True,
        default="",
    )
    usage = UsageInputSerializer(required=False, allow_null=True)

    def validate(self, attrs: dict) -> dict:
        if contains_secret(self.initial_data):
            raise serializers.ValidationError({"provider": ["不得向后端提交 API Key。"]})
        return attrs


class KeyPointUpdateSerializer(serializers.Serializer):
    is_key_point = serializers.BooleanField()
