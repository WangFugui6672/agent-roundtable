from __future__ import annotations

from urllib.parse import urlsplit

from rest_framework import serializers

from apps.roundtables.models import AgentProfile, Message, Roundtable, RoundtableAgent
from apps.roundtables.protocol import (
    BODY_HARD_MAX_CHARS,
    CLAIM_MAX_CHARS,
    DEFAULT_CONFIDENCE,
    MAX_REFERENCES,
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
            "provider",
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


class MessageSerializer(serializers.ModelSerializer):
    """Wire shape of one persisted utterance (docs/protocol.md 3.4 ``Message``)."""

    author = serializers.SerializerMethodField()
    references = serializers.SerializerMethodField()
    created_at = serializers.SerializerMethodField()
    stance = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = [
            "id",
            "author",
            "message_type",
            "claim",
            "body",
            "stance",
            "references",
            "confidence",
            "created_at",
        ]
        read_only_fields = fields

    def get_author(self, obj: Message) -> dict[str, str]:
        agent = obj.roundtable_agent
        return {
            "roundtable_agent_id": str(agent.id),
            "agent_key": agent.agent_profile.key,
            "name": agent.agent_profile.name,
        }

    def get_references(self, obj: Message) -> list[str]:
        return [str(reference.id) for reference in obj.references.all()]

    def get_stance(self, obj: Message) -> str | None:
        return obj.stance or None

    def get_created_at(self, obj: Message) -> str:
        return iso8601_millis(obj.created_at)


class MessageCreateSerializer(serializers.Serializer):
    """Request body of ``POST /api/v1/roundtables/{id}/messages``.

    Validation mirrors PRD 7.7: type, claim, body length, stance, references
    and confidence. ``max_reply_chars`` comes from the agent's profile so the
    client and the server agree on the cap.
    """

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
    confidence = serializers.FloatField(
        min_value=0, max_value=1, required=False, default=DEFAULT_CONFIDENCE
    )

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

        body = attrs.get("body", "")
        limit = agent.agent_profile.max_reply_chars
        if len(body) > limit:
            raise serializers.ValidationError({"body": f"正文超过 {limit} 字上限。"})
        if attrs["message_type"] != Message.Type.PASS and not body:
            raise serializers.ValidationError({"body": "正文不能为空。"})

        references = attrs.get("references") or []
        if len(set(references)) != len(references):
            raise serializers.ValidationError({"references": "引用消息不能重复。"})
        if references:
            found = Message.objects.filter(id__in=references, roundtable=roundtable).count()
            if found != len(references):
                raise serializers.ValidationError(
                    {"references": "引用的消息不存在或不属于此圆桌。"}
                )
        return attrs
