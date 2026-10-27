"""Request a replacement response through a new server-issued turn."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from apps.roundtables import protocol as p
from apps.roundtables.budget import MAX_TURN_SECONDS
from apps.roundtables.models import Message, Roundtable, RoundtableAgent, Turn
from apps.roundtables.services import (
    _append_room_event,
    _broadcast_after_commit,
    _event_envelope,
)
from apps.roundtables.statuses import AGENT_SPEAKING_STATUSES


@dataclass(frozen=True)
class RegenerationResult:
    round: int
    turn: Turn | None
    replacement_message_id: uuid.UUID | None
    events: list[dict[str, Any]]
    created: bool


def request_regeneration(
    roundtable_id: str,
    guest_session_id: str,
    message_id: str,
) -> RegenerationResult | None:
    """Create one replacement turn per message, returning it idempotently."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None

        message = (
            Message.objects.select_for_update(of=("self",))
            .select_related("roundtable_agent__agent_profile")
            .filter(id=message_id, roundtable=room)
            .first()
        )
        if message is None:
            raise ValidationError({"message_id": "消息不存在或不属于当前圆桌。"})
        if message.author_type != Message.AuthorType.AGENT or message.roundtable_agent is None:
            raise ValidationError({"message_id": "只能重新生成 AI 参与者的发言。"})

        existing = Turn.objects.select_for_update().filter(replaces_message=message).first()
        if existing is not None:
            return RegenerationResult(
                round=existing.round_number,
                turn=existing if existing.status == Turn.Status.PENDING else None,
                replacement_message_id=message.superseded_by_message_id,
                events=[],
                created=False,
            )

        if room.status not in AGENT_SPEAKING_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能重新生成发言。"})
        if Turn.objects.filter(roundtable=room, status=Turn.Status.PENDING).exists():
            raise ValidationError({"status": "当前已有待完成的 Agent 发言。"})

        agent = RoundtableAgent.objects.select_for_update().get(id=message.roundtable_agent_id)
        now = timezone.now()
        turn = Turn.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            roundtable_agent=agent,
            round_number=message.round_number,
            deadline_at=now + timedelta(seconds=MAX_TURN_SECONDS),
            replaces_message=message,
        )
        agent.state = RoundtableAgent.State.THINKING
        agent.save(update_fields=["state"])
        event = _append_room_event(
            room,
            p.AGENT_THINKING,
            {
                "turn_id": str(turn.id),
                "round": turn.round_number,
                "agent_id": str(agent.id),
                "agent_name": agent.agent_profile.name,
            },
        )
        room.save(update_fields=["event_sequence", "updated_at"])
        envelope = _event_envelope(event)
        _broadcast_after_commit(room.id, [envelope])
        return RegenerationResult(
            round=turn.round_number,
            turn=turn,
            replacement_message_id=None,
            events=[envelope],
            created=True,
        )
