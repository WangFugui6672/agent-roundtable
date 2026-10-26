from __future__ import annotations

from rest_framework import serializers

from apps.roundtables.models import AgentProfile, Roundtable, RoundtableAgent
from apps.roundtables.protocol import iso8601_millis

MVP_AGENT_COUNT = 3


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


class RoundtableSerializer(serializers.ModelSerializer):
    participants = ParticipantSerializer(source="agents", many=True, read_only=True)
    last_sequence = serializers.IntegerField(source="event_sequence", read_only=True)
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
            "created_at",
            "updated_at",
            "participants",
        ]
        read_only_fields = fields

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

    def validate_agent_profile_ids(self, value: list) -> list:
        if len(set(value)) != MVP_AGENT_COUNT:
            raise serializers.ValidationError("必须选择 3 个不同的 Agent。")
        found = AgentProfile.objects.filter(id__in=value).count()
        if found != MVP_AGENT_COUNT:
            raise serializers.ValidationError("Agent 不存在。")
        return value
