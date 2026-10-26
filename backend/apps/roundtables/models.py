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

    class ProviderKind(models.TextChoices):
        QWEN = "qwen", "通义千问"
        DEEPSEEK = "deepseek", "DeepSeek"
        CUSTOM = "custom", "自定义 OpenAI-compatible"

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
    pause_pending = models.BooleanField(default=False)
    # Provider metadata snapshot (Issue #3). Only non-secret fields are stored:
    # the API key lives in the iOS Keychain and must never reach Django.
    provider_kind = models.CharField(
        max_length=16, choices=ProviderKind.choices, blank=True, default=""
    )
    provider_base_url = models.CharField(max_length=300, blank=True, default="")
    provider_model = models.CharField(max_length=120, blank=True, default="")
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


class Turn(models.Model):
    """One server-issued speaking assignment executed by the iOS Provider."""

    class Status(models.TextChoices):
        PENDING = "pending", "待完成"
        COMPLETED = "completed", "已完成"
        PASSED = "passed", "已沉默"
        FAILED = "failed", "失败"
        CANCELLED = "cancelled", "已取消"

    id = models.UUIDField(primary_key=True, editable=False)
    roundtable = models.ForeignKey(Roundtable, on_delete=models.CASCADE, related_name="turns")
    roundtable_agent = models.ForeignKey(
        RoundtableAgent, on_delete=models.PROTECT, related_name="turns"
    )
    round_number = models.PositiveSmallIntegerField()
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(auto_now_add=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "turn"
        ordering = ["created_at", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["roundtable_agent", "round_number"],
                name="unique_turn_per_agent_round",
            ),
            models.UniqueConstraint(
                fields=["roundtable"],
                condition=models.Q(status="pending"),
                name="unique_pending_turn_per_roundtable",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.roundtable_agent}@{self.round_number}:{self.status}"


class Message(models.Model):
    """One structured agent utterance (GLOSSARY: 结构化发言)."""

    class Type(models.TextChoices):
        PROPOSAL = "proposal", "提出方案"
        SUPPORT = "support", "支持观点"
        CHALLENGE = "challenge", "质疑观点"
        SUPPLEMENT = "supplement", "补充观点"
        QUESTION = "question", "提出问题"
        PASS = "pass", "选择沉默"
        SUMMARY = "summary", "总结"
        USER_MESSAGE = "user_message", "用户消息"

    class AuthorType(models.TextChoices):
        AGENT = "agent", "Agent"
        USER = "user", "用户"

    class Stance(models.TextChoices):
        SUPPORT = "support", "支持"
        CHALLENGE = "challenge", "质疑"
        SUPPLEMENT = "supplement", "补充"
        QUESTION = "question", "提问"

    id = models.UUIDField(primary_key=True, editable=False)
    roundtable = models.ForeignKey(Roundtable, on_delete=models.CASCADE, related_name="messages")
    author_type = models.CharField(
        max_length=16, choices=AuthorType.choices, default=AuthorType.AGENT
    )
    roundtable_agent = models.ForeignKey(
        RoundtableAgent,
        on_delete=models.PROTECT,
        related_name="messages",
        null=True,
        blank=True,
    )
    turn = models.ForeignKey(
        Turn, on_delete=models.PROTECT, related_name="messages", null=True, blank=True
    )
    round_number = models.PositiveSmallIntegerField(default=0)
    message_type = models.CharField(max_length=16, choices=Type.choices, blank=True, default="")
    claim = models.CharField(max_length=80, blank=True, default="")
    body = models.TextField(blank=True, default="")
    stance = models.CharField(max_length=16, choices=Stance.choices, blank=True, default="")
    references = models.ManyToManyField("self", symmetrical=False, related_name="referenced_by")
    confidence = models.FloatField(default=0.6, null=True, blank=True)
    mentioned_agent_ids = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "message"
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.message_type}: {self.claim[:20]}"


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
