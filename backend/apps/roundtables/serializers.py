from __future__ import annotations

from urllib.parse import urlsplit

from rest_framework import serializers

from apps.roundtables.models import AgentProfile, Roundtable, RoundtableAgent
from apps.roundtables.protocol import iso8601_millis

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
            raise serializers.ValidationError({"provider": "不得向后端提交 API Key。"})
        return attrs

    def validate_agent_profile_ids(self, value: list) -> list:
        if len(set(value)) != MVP_AGENT_COUNT:
            raise serializers.ValidationError("必须选择 3 个不同的 Agent。")
        found = AgentProfile.objects.filter(id__in=value).count()
        if found != MVP_AGENT_COUNT:
            raise serializers.ValidationError("Agent 不存在。")
        return value
