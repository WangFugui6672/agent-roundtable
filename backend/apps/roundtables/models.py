from __future__ import annotations

from django.db import models


class GuestSession(models.Model):
    """Anonymous device session. The UUID itself is the bearer capability in MVP."""

    id = models.UUIDField(primary_key=True, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "guest_session"

    def __str__(self) -> str:
        return str(self.id)


class AgentProfile(models.Model):
    """Reusable definition of an AI participant (GLOSSARY: AgentProfile)."""

    class Key(models.TextChoices):
        ADVOCATE = "advocate", "方案派"
        SKEPTIC = "skeptic", "质疑派"
        EXPERIENCE = "experience", "体验派"

    id = models.UUIDField(primary_key=True, editable=False)
    key = models.CharField(max_length=32, unique=True, choices=Key.choices)
    name = models.CharField(max_length=64)
    tagline = models.CharField(max_length=200)
    expertise = models.CharField(max_length=200)
    goal = models.CharField(max_length=200)
    default_stance = models.CharField(max_length=200)
    style = models.CharField(max_length=200)
    banned_behaviors = models.JSONField(default=list)
    max_reply_chars = models.PositiveIntegerField(default=180)
    sort_order = models.PositiveSmallIntegerField(default=0)

    class Meta:
        db_table = "agent_profile"
        ordering = ["sort_order", "name"]

    def __str__(self) -> str:
        return self.name


class Roundtable(models.Model):
    """A discussion session around one topic (GLOSSARY: 圆桌)."""

    class Status(models.TextChoices):
        DRAFT = "draft", "草稿"
        READY = "ready", "就绪"
        RUNNING = "running", "进行中"
        PAUSED = "paused", "已暂停"
        SUMMARIZING = "summarizing", "总结中"
        COMPLETED = "completed", "已完成"
        FAILED = "failed", "失败"
        ARCHIVED = "archived", "已归档"

    class Mode(models.TextChoices):
        DECISION = "decision", "决策讨论"

    id = models.UUIDField(primary_key=True, editable=False)
    guest_session = models.ForeignKey(
        GuestSession, on_delete=models.CASCADE, related_name="roundtables"
    )
    topic = models.CharField(max_length=500)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.READY)
    mode = models.CharField(max_length=16, choices=Mode.choices, default=Mode.DECISION)
    max_rounds = models.PositiveSmallIntegerField(default=2)
    current_round = models.PositiveSmallIntegerField(default=0)
    event_sequence = models.BigIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "roundtable"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.topic[:20]} ({self.status})"


class RoundtableAgent(models.Model):
    """AgentProfile instance inside one roundtable (GLOSSARY: RoundtableAgent)."""

    class State(models.TextChoices):
        WAITING = "waiting", "等待"
        THINKING = "thinking", "思考中"
        TYPING = "typing", "输入中"
        PASSED = "passed", "沉默"
        COMPLETED = "completed", "已完成"
        FAILED = "failed", "失败"

    id = models.UUIDField(primary_key=True, editable=False)
    roundtable = models.ForeignKey(Roundtable, on_delete=models.CASCADE, related_name="agents")
    agent_profile = models.ForeignKey(AgentProfile, on_delete=models.PROTECT, related_name="+")
    position = models.PositiveSmallIntegerField()
    state = models.CharField(max_length=16, choices=State.choices, default=State.WAITING)

    class Meta:
        db_table = "roundtable_agent"
        ordering = ["position"]
        constraints = [
            models.UniqueConstraint(
                fields=["roundtable", "agent_profile"], name="unique_agent_per_roundtable"
            ),
            models.UniqueConstraint(
                fields=["roundtable", "position"], name="unique_position_per_roundtable"
            ),
        ]

    def __str__(self) -> str:
        return f"{self.agent_profile.name}@{self.position}"


class RoomEvent(models.Model):
    """Persisted WebSocket event, used for cursor replay (GLOSSARY: Event)."""

    id = models.UUIDField(primary_key=True, editable=False)
    roundtable = models.ForeignKey(Roundtable, on_delete=models.CASCADE, related_name="events")
    sequence = models.BigIntegerField()
    event_type = models.CharField(max_length=64)
    payload = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "room_event"
        ordering = ["sequence"]
        constraints = [
            models.UniqueConstraint(
                fields=["roundtable", "sequence"], name="unique_sequence_per_roundtable"
            )
        ]

    def __str__(self) -> str:
        return f"{self.sequence}:{self.event_type}"
