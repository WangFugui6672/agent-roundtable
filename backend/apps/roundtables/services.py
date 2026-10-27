"""Database-facing services used by both REST views and the WS consumer."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from django.conf import settings
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from apps.roundtables import mock
from apps.roundtables import protocol as p
from apps.roundtables.budget import (
    ACTIVE_STATUSES,
    MAX_ACTIVE_ROUNDTABLES,
    MAX_TURN_SECONDS,
)
from apps.roundtables.commands import TurnFailureCommand
from apps.roundtables.message_validation import validate_agent_message
from apps.roundtables.models import (
    GuestSession,
    Message,
    MessageReport,
    RoomEvent,
    RoundSummary,
    Roundtable,
    RoundtableAgent,
    Turn,
    UsageRecord,
)
from apps.roundtables.scheduler import select_next_speaker
from apps.roundtables.serializers import (
    MessageSerializer,
    RoundSummarySerializer,
    RoundtableSerializer,
    TurnSerializer,
)
from apps.roundtables.statuses import (
    AGENT_SPEAKING_STATUSES,
    NON_SCHEDULING_STATUSES,
    READ_ONLY_STATUSES,
    SUMMARY_STATUSES,
)
from roundtable.exceptions import ActiveRoundtableLimit, SummaryVersionConflict


@dataclass(frozen=True)
class RoomCommandResult:
    room: Roundtable
    events: list[dict[str, Any]]


@dataclass(frozen=True)
class SummaryCommandResult:
    room: Roundtable
    summary: RoundSummary
    events: list[dict[str, Any]]
    created: bool


@dataclass(frozen=True)
class MessageReportResult:
    report: MessageReport
    created: bool


def _event_envelope(event: RoomEvent) -> dict[str, Any]:
    return p.make_envelope(
        event_id=str(event.id),
        room_id=str(event.roundtable_id),
        sequence=event.sequence,
        event_type=event.event_type,
        payload=event.payload,
        created_at=p.iso8601_millis(event.created_at),
    )


def _append_room_event(
    room: Roundtable,
    event_type: str,
    payload: dict[str, Any],
) -> RoomEvent:
    """Allocate the next room sequence and append one persisted event."""
    room.event_sequence += 1
    return RoomEvent.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        sequence=room.event_sequence,
        event_type=event_type,
        payload=payload,
    )


def _record_usage(
    turn: Turn,
    usage: dict[str, Any] | None,
    *,
    failure_code: str = "",
) -> UsageRecord:
    values = usage or {}
    fields = {
        "roundtable": turn.roundtable,
        "roundtable_agent": turn.roundtable_agent,
        "provider_kind": turn.roundtable.provider_kind,
        "provider_model": turn.roundtable.provider_model,
        "input_tokens": values.get("input_tokens"),
        "output_tokens": values.get("output_tokens"),
        "latency_ms": values.get("latency_ms"),
        "retry_count": values.get("retry_count", 0),
        "failure_code": failure_code,
    }
    record, created = UsageRecord.objects.get_or_create(
        turn=turn,
        defaults={"id": uuid.uuid4(), **fields},
    )
    if not created:
        for field, value in fields.items():
            setattr(record, field, value)
        record.save(update_fields=[*fields, "updated_at"])
    totals = UsageRecord.objects.filter(roundtable=turn.roundtable).aggregate(
        input_tokens=Sum("input_tokens"),
        output_tokens=Sum("output_tokens"),
    )
    turn.roundtable.reported_tokens = (totals["input_tokens"] or 0) + (totals["output_tokens"] or 0)
    turn.roundtable.save(update_fields=["reported_tokens", "updated_at"])
    return record


def _room_for_session(roundtable_id: str, guest_session_id: str) -> Roundtable | None:
    return (
        Roundtable.objects.filter(id=roundtable_id, guest_session_id=guest_session_id)
        .prefetch_related("agents__agent_profile")
        .first()
    )


def _room_access_allowed(roundtable_id: str, guest_session_id: str) -> bool:
    return Roundtable.objects.filter(
        id=roundtable_id,
        guest_session_id=guest_session_id,
    ).exists()


def _turn_failure_payload(turn: Turn) -> dict[str, Any]:
    agent = turn.roundtable_agent
    return {
        "turn_id": str(turn.id),
        "round": turn.round_number,
        "agent_id": str(agent.id),
        "agent_name": agent.agent_profile.name,
        "failure_code": turn.failure_code,
        "message": turn.failure_message,
        "retryable": turn.retryable,
        "partial": turn.failure_partial or None,
    }


def _budget_exhaustion_reason(room: Roundtable) -> str | None:
    if (
        room.started_at is not None
        and (timezone.now() - room.started_at).total_seconds() >= room.max_duration_seconds
    ):
        return "duration"
    if (
        room.messages.filter(author_type=Message.AuthorType.AGENT).count()
        >= room.max_agent_messages
    ):
        return "agent_messages"
    if room.reported_tokens >= room.max_reported_tokens:
        return "reported_tokens"
    return None


def _budget_exhausted_payload(room: Roundtable, reason: str) -> dict[str, Any]:
    messages = {
        "duration": f"讨论已达到 {room.max_duration_seconds} 秒时间上限。",
        "agent_messages": f"讨论已达到 {room.max_agent_messages} 条消息上限。",
        "reported_tokens": f"讨论已达到 {room.max_reported_tokens} Token 上报上限。",
    }
    return {
        "reason": reason,
        "message": messages[reason],
        "round": room.current_round,
    }


def _normalize_summary_items(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "text": item["text"],
            "reference_message_ids": [
                str(message_id) for message_id in item["reference_message_ids"]
            ],
        }
        for item in items
    ]


def _validate_summary_references(
    room: Roundtable,
    normalized: dict[str, list[dict[str, Any]]],
) -> None:
    reference_ids = {
        message_id
        for key in ("consensus", "dissent", "recommendations", "unresolved")
        for item in normalized[key]
        for message_id in item["reference_message_ids"]
    }
    opinions = Message.objects.filter(
        id__in=reference_ids,
        roundtable=room,
        author_type=Message.AuthorType.AGENT,
        message_type__in={
            Message.Type.PROPOSAL,
            Message.Type.SUPPORT,
            Message.Type.CHALLENGE,
            Message.Type.SUPPLEMENT,
            Message.Type.QUESTION,
        },
    )
    found = {str(message_id) for message_id in opinions.values_list("id", flat=True)}
    if found != reference_ids:
        raise ValidationError(
            {"reference_message_ids": ("结论引用必须指向当前圆桌中已经存在的有效 Agent 观点。")}
        )


def submit_summary(
    roundtable_id: str,
    guest_session_id: str,
    validated: dict[str, Any],
) -> SummaryCommandResult | None:
    """Create or regenerate the structured result for a completed discussion."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None

        summary = RoundSummary.objects.select_for_update().filter(roundtable=room).first()
        if summary is None and room.status != Roundtable.Status.SUMMARIZING:
            raise ValidationError({"status": "第二轮结束后才能提交结论。"})
        if room.status not in SUMMARY_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能提交结论。"})
        ended_early = room.events.filter(event_type=p.ROOM_ENDED).exists()
        if room.current_round < room.max_rounds and not ended_early:
            raise ValidationError({"status": "第二轮尚未完成，不能提交结论。"})

        normalized = {
            key: _normalize_summary_items(validated[key])
            for key in ("consensus", "dissent", "recommendations", "unresolved")
        }
        _validate_summary_references(room, normalized)

        expected_version = validated["expected_version"]
        if summary is None:
            if expected_version != 0:
                raise SummaryVersionConflict(message="尚未存在结论，expected_version 必须为 0。")
            summary = RoundSummary.objects.create(
                id=uuid.uuid4(),
                roundtable=room,
                degraded=validated["degraded"],
                version=1,
                **normalized,
            )
        else:
            content_matches = (
                summary.consensus == normalized["consensus"]
                and summary.dissent == normalized["dissent"]
                and summary.recommendations == normalized["recommendations"]
                and summary.unresolved == normalized["unresolved"]
                and summary.degraded == validated["degraded"]
            )
            if expected_version != summary.version:
                if expected_version == summary.version - 1 and content_matches:
                    return SummaryCommandResult(
                        room=room,
                        summary=summary,
                        events=[],
                        created=False,
                    )
                raise SummaryVersionConflict()
            summary.degraded = validated["degraded"]
            summary.version += 1
            for key, items in normalized.items():
                setattr(summary, key, items)
            summary.save(
                update_fields=[
                    "degraded",
                    "version",
                    "consensus",
                    "dissent",
                    "recommendations",
                    "unresolved",
                    "updated_at",
                ]
            )

        room.status = Roundtable.Status.COMPLETED
        room.pause_pending = False
        event = _append_room_event(
            room,
            p.SUMMARY_COMPLETED,
            {"summary": RoundSummarySerializer(summary).data},
        )
        room.save(
            update_fields=[
                "status",
                "pause_pending",
                "event_sequence",
                "updated_at",
            ]
        )
        envelope = _event_envelope(event)
        _broadcast_after_commit(room.id, [envelope])
        return SummaryCommandResult(
            room=room,
            summary=summary,
            events=[envelope],
            created=True,
        )


def create_follow_up(
    roundtable_id: str,
    guest_session_id: str,
    topic: str,
) -> Roundtable | None:
    """Create a fresh read/write room that keeps an explicit parent summary link."""
    with transaction.atomic():
        parent = (
            Roundtable.objects.select_for_update()
            .prefetch_related("agents__agent_profile")
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if parent is None:
            return None
        if parent.status != Roundtable.Status.COMPLETED:
            raise ValidationError({"status": "只有已完成圆桌可以继续追问。"})
        summary = RoundSummary.objects.filter(roundtable=parent).first()
        if summary is None:
            raise ValidationError({"summary": "当前圆桌还没有可用的结论。"})

        GuestSession.objects.select_for_update().get(id=parent.guest_session_id)
        active_count = Roundtable.objects.filter(
            guest_session_id=parent.guest_session_id,
            status__in=ACTIVE_STATUSES,
        ).count()
        if active_count >= MAX_ACTIVE_ROUNDTABLES:
            raise ActiveRoundtableLimit()

        follow_up = Roundtable.objects.create(
            id=uuid.uuid4(),
            guest_session_id=parent.guest_session_id,
            topic=topic,
            provider_kind=parent.provider_kind,
            provider_base_url=parent.provider_base_url,
            provider_model=parent.provider_model,
            parent_roundtable=parent,
            source_summary=summary,
        )
        for agent in parent.agents.all():
            RoundtableAgent.objects.create(
                id=uuid.uuid4(),
                roundtable=follow_up,
                agent_profile=agent.agent_profile,
                position=agent.position,
            )
        return _room_for_session(str(follow_up.id), str(parent.guest_session_id))


def _expire_pending_turn(room: Roundtable, turn: Turn) -> RoomEvent:
    agent = turn.roundtable_agent
    turn.status = Turn.Status.FAILED
    turn.failure_code = "turn_timeout"
    turn.failure_message = f"单个 Agent 的生成超过 {MAX_TURN_SECONDS} 秒上限。"
    turn.failure_partial = ""
    turn.retryable = True
    turn.completed_at = timezone.now()
    turn.save(
        update_fields=[
            "status",
            "failure_code",
            "failure_message",
            "failure_partial",
            "retryable",
            "completed_at",
        ]
    )
    agent.state = RoundtableAgent.State.FAILED
    agent.save(update_fields=["state"])
    return _append_room_event(room, p.AGENT_FAILED, _turn_failure_payload(turn))


def build_join_envelope(
    room: Roundtable,
    replay: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """``room.joined`` is an ephemeral snapshot, so its sequence stays 0."""
    messages = (
        room.messages.select_related("roundtable_agent__agent_profile")
        .prefetch_related("references")
        .all()
    )
    failures = room.turns.filter(status=Turn.Status.FAILED).select_related(
        "roundtable_agent__agent_profile"
    )
    summary = RoundSummary.objects.filter(roundtable=room).first()
    payload: dict[str, Any] = {
        "roundtable": RoundtableSerializer(room).data,
        "messages": MessageSerializer(messages, many=True).data,
        "failures": [_turn_failure_payload(turn) for turn in failures],
        "summary": RoundSummarySerializer(summary).data if summary else None,
    }
    if replay is not None:
        payload["replay"] = replay
    return p.make_envelope(
        event_id=p.new_event_id(),
        room_id=str(room.id),
        sequence=p.EPHEMERAL_SEQUENCE,
        event_type=p.ROOM_JOINED,
        payload=payload,
    )


def room_group_name(roundtable_id: object) -> str:
    """Channel-layer group for one room; REST writes fan out through it."""
    return f"room.{roundtable_id}"


def _broadcast_room_events(roundtable_id: object, envelopes: list[dict[str, Any]]) -> None:
    channel_layer = get_channel_layer()
    if channel_layer is None:
        return
    group = room_group_name(roundtable_id)
    for envelope in envelopes:
        async_to_sync(channel_layer.group_send)(
            group,
            {"type": "room.event", "envelope": envelope},
        )


def _broadcast_after_commit(roundtable_id: object, envelopes: list[dict[str, Any]]) -> None:
    if not envelopes:
        return
    transaction.on_commit(lambda: _broadcast_room_events(roundtable_id, envelopes))


def _replay_metadata(room: Roundtable, cursor: int) -> dict[str, Any]:
    cutoff = timezone.now() - timedelta(days=settings.ROOM_EVENT_REPLAY_WINDOW_DAYS)
    oldest_sequence = (
        room.events.filter(created_at__gte=cutoff)
        .order_by("sequence")
        .values_list("sequence", flat=True)
        .first()
    )
    latest_sequence = room.event_sequence
    missing_from_window = cursor < latest_sequence and (
        oldest_sequence is None or oldest_sequence > cursor + 1
    )
    return {
        "requested_cursor": cursor,
        "oldest_sequence": oldest_sequence,
        "latest_sequence": latest_sequence,
        "window_days": settings.ROOM_EVENT_REPLAY_WINDOW_DAYS,
        "cursor_expired": cursor > latest_sequence or missing_from_window,
    }


def _join_snapshot(
    roundtable_id: str,
    guest_session_id: str,
    cursor: int = 0,
) -> dict[str, Any] | None:
    room = _room_for_session(roundtable_id, guest_session_id)
    if room is None:
        return None
    now = timezone.now()
    GuestSession.objects.filter(id=guest_session_id).update(last_seen_at=now)
    room.last_activity_at = now
    room.save(update_fields=["last_activity_at", "updated_at"])
    return build_join_envelope(room, replay=_replay_metadata(room, cursor))


def _events_after(roundtable_id: str, guest_session_id: str, cursor: int) -> list[dict[str, Any]]:
    if _room_for_session(roundtable_id, guest_session_id) is None:
        return []
    cutoff = timezone.now() - timedelta(days=settings.ROOM_EVENT_REPLAY_WINDOW_DAYS)
    events = RoomEvent.objects.filter(
        roundtable_id=roundtable_id,
        sequence__gt=cursor,
        created_at__gte=cutoff,
    ).order_by("sequence")
    return [_event_envelope(event) for event in events]


def _preferred_agent_ids(room: Roundtable, agents: list[RoundtableAgent]) -> list[str]:
    waiting_ids = {
        str(agent.id) for agent in agents if agent.state == RoundtableAgent.State.WAITING
    }
    if not waiting_ids:
        return []
    user_messages = room.messages.filter(author_type=Message.AuthorType.USER).order_by(
        "-created_at", "-id"
    )
    for message in user_messages:
        mentioned = [
            agent_id for agent_id in message.mentioned_agent_ids if agent_id in waiting_ids
        ]
        if mentioned:
            return mentioned
    return []


def _run_mock_round(roundtable_id: str, guest_session_id: str) -> list[dict[str, Any]]:
    """Persist and return the next scripted mock round, if the budget allows it."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if (
            room is None
            or room.status not in AGENT_SPEAKING_STATUSES
            or room.current_round >= room.max_rounds
        ):
            return []

        now = timezone.now()
        if room.started_at is None:
            room.started_at = now
        reason = _budget_exhaustion_reason(room)
        if reason is not None:
            room.status = Roundtable.Status.COMPLETED
            room.budget_exhausted_reason = reason
            event = _append_room_event(
                room,
                p.ROOM_BUDGET_EXHAUSTED,
                _budget_exhausted_payload(room, reason),
            )
            room.save(
                update_fields=[
                    "started_at",
                    "status",
                    "budget_exhausted_reason",
                    "event_sequence",
                    "updated_at",
                ]
            )
            return [_event_envelope(event)]

        agents = list(room.agents.select_related("agent_profile").order_by("position"))
        round_number = room.current_round + 1
        script = mock.build_mock_round(room, agents, round_number)

        agents_by_id = {str(agent.id): agent for agent in agents}
        created: list[RoomEvent] = []
        persisted_messages: dict[str, Message] = {}
        for event_type, payload in script:
            if event_type == p.ROUND_STARTED:
                for agent in agents:
                    agent.state = RoundtableAgent.State.WAITING
            elif event_type == p.AGENT_THINKING:
                agents_by_id[payload["agent_id"]].state = RoundtableAgent.State.THINKING
            elif event_type == p.AGENT_TYPING:
                agents_by_id[payload["agent_id"]].state = RoundtableAgent.State.TYPING
            elif event_type == p.MESSAGE_COMPLETED:
                message_data = payload["message"]
                author_id = message_data["author"]["roundtable_agent_id"]
                agents_by_id[author_id].state = RoundtableAgent.State.COMPLETED
                message = Message.objects.create(
                    id=message_data["id"],
                    roundtable=room,
                    author_type=Message.AuthorType.AGENT,
                    roundtable_agent=agents_by_id[author_id],
                    turn=None,
                    round_number=message_data["round_number"],
                    message_type=message_data["message_type"],
                    claim=message_data["claim"],
                    body=message_data["body"],
                    stance=message_data["stance"] or "",
                    challenge_target_id=message_data["challenge_target_agent_id"],
                    confidence=message_data["confidence"],
                )
                persisted_messages[str(message.id)] = message

            created.append(_append_room_event(room, event_type, payload))

        for event_type, payload in script:
            if event_type != p.MESSAGE_COMPLETED:
                continue
            message_data = payload["message"]
            reference_ids = message_data["references"]
            if reference_ids:
                persisted_messages[message_data["id"]].references.set(
                    [persisted_messages[reference_id] for reference_id in reference_ids]
                )

        RoundtableAgent.objects.bulk_update(agents, ["state"])

        room.current_round = round_number
        if round_number >= room.max_rounds:
            room.status = Roundtable.Status.SUMMARIZING
            created.append(
                _append_room_event(
                    room,
                    p.SUMMARY_STARTED,
                    {"round": round_number},
                )
            )
        else:
            room.status = Roundtable.Status.RUNNING
        room.save(
            update_fields=[
                "current_round",
                "status",
                "started_at",
                "event_sequence",
                "updated_at",
            ]
        )

        return [_event_envelope(event) for event in created]


def create_user_message(
    roundtable_id: str,
    guest_session_id: str,
    body: str,
    mentioned_agent_ids: list[str],
) -> RoomCommandResult | None:
    """Persist a user utterance and pause automatic discussion at a safe boundary."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .prefetch_related("agents__agent_profile")
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status in READ_ONLY_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不允许发送消息。"})

        pending_turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        message = Message.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            author_type=Message.AuthorType.USER,
            roundtable_agent=None,
            turn=None,
            round_number=room.current_round,
            message_type=Message.Type.USER_MESSAGE,
            claim="",
            body=body,
            stance="",
            confidence=None,
            mentioned_agent_ids=mentioned_agent_ids,
        )

        created = [
            _append_room_event(
                room,
                p.MESSAGE_COMPLETED,
                {"message": MessageSerializer(message).data},
            )
        ]
        if pending_turn is not None:
            if not room.pause_pending:
                room.pause_pending = True
                created.append(
                    _append_room_event(
                        room,
                        p.ROOM_PAUSE_PENDING,
                        {"turn_id": str(pending_turn.id)},
                    )
                )
        elif room.status != Roundtable.Status.PAUSED:
            room.status = Roundtable.Status.PAUSED
            room.pause_pending = False
            created.append(
                _append_room_event(
                    room,
                    p.ROOM_PAUSED,
                    {"status": Roundtable.Status.PAUSED},
                )
            )

        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelopes = [_event_envelope(event) for event in created]
        _broadcast_after_commit(room.id, envelopes)
        return RoomCommandResult(room=room, events=envelopes)


def submit_message_report(
    roundtable_id: str,
    guest_session_id: str,
    message_id: str,
    reason: str,
    details: str,
) -> MessageReportResult | None:
    """Record one AI-message report idempotently for the owning session."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        message = Message.objects.filter(
            id=message_id,
            roundtable=room,
            author_type=Message.AuthorType.AGENT,
        ).first()
        if message is None:
            raise ValidationError({"message_id": "只能举报当前圆桌中的 AI 消息。"})

        report, created = MessageReport.objects.get_or_create(
            guest_session_id=guest_session_id,
            message=message,
            defaults={
                "id": uuid.uuid4(),
                "roundtable": room,
                "reason": reason,
                "details": details,
            },
        )
        room.last_activity_at = timezone.now()
        room.save(update_fields=["last_activity_at", "updated_at"])
        return MessageReportResult(report=report, created=created)


def delete_roundtable(roundtable_id: str, guest_session_id: str) -> str | None:
    """Delete a room and all child data; return ``missing`` on a repeated delete."""
    with transaction.atomic():
        room = Roundtable.objects.select_for_update().filter(id=roundtable_id).first()
        if room is None:
            return "missing"
        if str(room.guest_session_id) != guest_session_id:
            return None
        _delete_room_data(room)
        return "deleted"


def _delete_room_data(room: Roundtable) -> None:
    """Delete PROTECT-linked children before the room itself."""
    MessageReport.objects.filter(roundtable=room).delete()
    UsageRecord.objects.filter(roundtable=room).delete()
    RoundSummary.objects.filter(roundtable=room).delete()
    Message.objects.filter(roundtable=room).delete()
    Turn.objects.filter(roundtable=room).delete()
    RoomEvent.objects.filter(roundtable=room).delete()
    RoundtableAgent.objects.filter(roundtable=room).delete()
    room.delete()


def purge_expired_roundtables(now=None) -> int:
    """Delete rooms at or beyond the retention boundary and orphaned sessions."""
    now = now or timezone.now()
    cutoff = now - timedelta(days=settings.ROUNDTABLE_RETENTION_DAYS)
    deleted = 0
    with transaction.atomic():
        rooms = list(Roundtable.objects.select_for_update().filter(last_activity_at__lte=cutoff))
        for room in rooms:
            _delete_room_data(room)
            deleted += 1

        GuestSession.objects.filter(
            last_seen_at__lte=cutoff,
            roundtables__isnull=True,
        ).delete()
    return deleted


def pause_room(roundtable_id: str, guest_session_id: str) -> RoomCommandResult | None:
    """Pause now, or at the current turn boundary when one is in flight."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .prefetch_related("agents__agent_profile")
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status == Roundtable.Status.PAUSED:
            return RoomCommandResult(room=room, events=[])
        if room.status in READ_ONLY_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不允许暂停。"})

        pending_turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        if pending_turn is not None:
            if room.pause_pending:
                return RoomCommandResult(room=room, events=[])
            room.pause_pending = True
            event = _append_room_event(
                room,
                p.ROOM_PAUSE_PENDING,
                {"turn_id": str(pending_turn.id)},
            )
        else:
            room.status = Roundtable.Status.PAUSED
            room.pause_pending = False
            event = _append_room_event(
                room,
                p.ROOM_PAUSED,
                {"status": Roundtable.Status.PAUSED},
            )

        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelope = _event_envelope(event)
        _broadcast_after_commit(room.id, [envelope])
        return RoomCommandResult(room=room, events=[envelope])


def resume_room(roundtable_id: str, guest_session_id: str) -> RoomCommandResult | None:
    """Resume a paused room, or cancel an unconsumed pause-pending flag."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .prefetch_related("agents__agent_profile")
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status in READ_ONLY_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不允许继续。"})
        if room.status != Roundtable.Status.PAUSED and not room.pause_pending:
            return RoomCommandResult(room=room, events=[])

        room.status = Roundtable.Status.RUNNING
        room.pause_pending = False
        event = _append_room_event(
            room,
            p.ROOM_RESUMED,
            {"status": Roundtable.Status.RUNNING},
        )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelope = _event_envelope(event)
        _broadcast_after_commit(room.id, [envelope])
        return RoomCommandResult(room=room, events=[envelope])


def end_room(roundtable_id: str, guest_session_id: str) -> RoomCommandResult | None:
    """End the room and invalidate any in-flight turn exactly once."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .prefetch_related("agents__agent_profile")
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status in SUMMARY_STATUSES:
            return RoomCommandResult(room=room, events=[])

        pending_turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        cancelled_turn_id = None
        cancelled_agent_id = None
        if pending_turn is not None:
            cancelled_turn_id = str(pending_turn.id)
            cancelled_agent_id = str(pending_turn.roundtable_agent_id)
            pending_turn.status = Turn.Status.CANCELLED
            pending_turn.completed_at = timezone.now()
            pending_turn.save(update_fields=["status", "completed_at"])
            agent = next(
                agent for agent in room.agents.all() if agent.id == pending_turn.roundtable_agent_id
            )
            agent.state = RoundtableAgent.State.WAITING
            agent.save(update_fields=["state"])

        room.status = Roundtable.Status.SUMMARIZING
        room.pause_pending = False
        ended_event = _append_room_event(
            room,
            p.ROOM_ENDED,
            {
                "status": Roundtable.Status.SUMMARIZING,
                "cancelled_turn_id": cancelled_turn_id,
                "cancelled_agent_id": cancelled_agent_id,
            },
        )
        summary_event = _append_room_event(
            room,
            p.SUMMARY_STARTED,
            {"round": room.current_round},
        )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelopes = [
            _event_envelope(ended_event),
            _event_envelope(summary_event),
        ]
        _broadcast_after_commit(room.id, envelopes)
        return RoomCommandResult(room=room, events=envelopes)


def create_message(
    roundtable_id: str, guest_session_id: str, validated: dict[str, Any]
) -> dict[str, Any] | None:
    """Persist one structured utterance and the matching ``message.completed`` event.

    Returns the event envelope, or ``None`` when the room does not belong to the
    guest session (the view turns that into 404).
    """
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status not in AGENT_SPEAKING_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能提交 Agent 消息。"})

        agent = (
            RoundtableAgent.objects.select_for_update()
            .select_related("agent_profile")
            .get(id=validated["roundtable_agent_id"])
        )
        turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        if turn is None or turn.id != validated.get("turn_id"):
            raise ValidationError({"turn_id": "turn 已过期、重复或不属于当前圆桌。"})
        if turn.roundtable_agent_id != agent.id:
            raise ValidationError({"roundtable_agent_id": "提交者不是当前 turn 的发言人。"})
        validate_agent_message(
            roundtable=room,
            agent=agent,
            turn=turn,
            data=validated,
        )
        message = Message.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            roundtable_agent=agent,
            turn=turn,
            round_number=turn.round_number,
            message_type=validated["message_type"],
            claim=validated["claim"],
            body=validated.get("body", ""),
            stance=validated.get("stance") or "",
            confidence=validated.get("confidence", 0.6),
            challenge_target_id=validated.get("challenge_target_agent_id"),
            supersedes_id=turn.replaces_message_id,
        )
        message.references.set(validated.get("references") or [])
        _record_usage(turn, validated.get("usage"))

        turn.status = Turn.Status.COMPLETED
        turn.completed_at = timezone.now()
        turn.save(update_fields=["status", "completed_at"])
        agent.state = RoundtableAgent.State.COMPLETED
        agent.save(update_fields=["state"])

        message_event = _append_room_event(
            room,
            p.MESSAGE_COMPLETED,
            {"message": MessageSerializer(message).data},
        )
        events = [message_event]
        if room.pause_pending:
            room.status = Roundtable.Status.PAUSED
            room.pause_pending = False
            events.append(
                _append_room_event(
                    room,
                    p.ROOM_PAUSED,
                    {"status": Roundtable.Status.PAUSED},
                )
            )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelopes = [_event_envelope(event) for event in events]
        _broadcast_after_commit(room.id, envelopes)
        envelope = envelopes[0]
        return envelope


def next_turn(
    roundtable_id: str, guest_session_id: str
) -> tuple[int, dict[str, Any] | None, list[dict[str, Any]]] | None:
    """Begin the first round and reserve exactly one Agent to speak."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status == Roundtable.Status.COMPLETED:
            raise ValidationError({"status": "圆桌当前状态不能签发新的 turn。"})
        if room.status in NON_SCHEDULING_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能签发新的 turn。"})

        agents = list(
            RoundtableAgent.objects.select_for_update()
            .filter(roundtable=room)
            .select_related("agent_profile")
            .order_by("position")
        )
        preferred_ids = _preferred_agent_ids(room, agents)
        now = timezone.now()
        if room.current_round == 0:
            room.current_round = 1
            room.status = Roundtable.Status.RUNNING
            room.started_at = now
            for agent in agents:
                agent.state = RoundtableAgent.State.WAITING
            speaker = select_next_speaker(agents, preferred_ids)
            if speaker is None:
                raise RuntimeError("A roundtable must have a participant.")
            speaker.state = RoundtableAgent.State.THINKING
            RoundtableAgent.objects.bulk_update(agents, ["state"])
            turn = Turn.objects.create(
                id=uuid.uuid4(),
                roundtable=room,
                roundtable_agent=speaker,
                round_number=1,
                deadline_at=now + timedelta(seconds=MAX_TURN_SECONDS),
            )

            events = [
                (
                    p.ROUND_STARTED,
                    {"round": 1, "max_rounds": room.max_rounds, "topic": room.topic},
                ),
                (
                    p.AGENT_THINKING,
                    {
                        "turn_id": str(turn.id),
                        "round": 1,
                        "agent_id": str(speaker.id),
                        "agent_name": speaker.agent_profile.name,
                    },
                ),
            ]
            created: list[RoomEvent] = []
            for event_type, payload in events:
                created.append(_append_room_event(room, event_type, payload))
            room.save(
                update_fields=[
                    "current_round",
                    "status",
                    "started_at",
                    "event_sequence",
                    "updated_at",
                ]
            )
            envelopes = [_event_envelope(event) for event in created]
            _broadcast_after_commit(room.id, envelopes)
            return 1, TurnSerializer(turn).data, envelopes

        pending_events: list[RoomEvent] = []
        active_turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .select_related("roundtable_agent__agent_profile")
            .first()
        )
        if active_turn is not None:
            if active_turn.deadline_at is not None and active_turn.deadline_at <= now:
                pending_events.append(_expire_pending_turn(room, active_turn))
                for agent in agents:
                    if agent.id == active_turn.roundtable_agent_id:
                        agent.state = RoundtableAgent.State.FAILED
                        break
                if room.pause_pending:
                    room.status = Roundtable.Status.PAUSED
                    room.pause_pending = False
                    pending_events.append(
                        _append_room_event(
                            room,
                            p.ROOM_PAUSED,
                            {"status": Roundtable.Status.PAUSED},
                        )
                    )
                    room.save(
                        update_fields=[
                            "status",
                            "pause_pending",
                            "event_sequence",
                            "updated_at",
                        ]
                    )
                    envelopes = [_event_envelope(event) for event in pending_events]
                    _broadcast_after_commit(room.id, envelopes)
                    return room.current_round, None, envelopes
            else:
                return room.current_round, TurnSerializer(active_turn).data, []

        speaker = select_next_speaker(agents, preferred_ids)
        if speaker is not None:
            reason = _budget_exhaustion_reason(room)
            if reason is not None:
                room.status = Roundtable.Status.COMPLETED
                room.budget_exhausted_reason = reason
                event = _append_room_event(
                    room,
                    p.ROOM_BUDGET_EXHAUSTED,
                    _budget_exhausted_payload(room, reason),
                )
                room.save(
                    update_fields=[
                        "status",
                        "budget_exhausted_reason",
                        "event_sequence",
                        "updated_at",
                    ]
                )
                envelopes = [_event_envelope(room_event) for room_event in [*pending_events, event]]
                _broadcast_after_commit(room.id, envelopes)
                return room.current_round, None, envelopes
            speaker.state = RoundtableAgent.State.THINKING
            speaker.save(update_fields=["state"])
            turn = Turn.objects.create(
                id=uuid.uuid4(),
                roundtable=room,
                roundtable_agent=speaker,
                round_number=room.current_round,
                deadline_at=now + timedelta(seconds=MAX_TURN_SECONDS),
            )
            event = _append_room_event(
                room,
                p.AGENT_THINKING,
                {
                    "turn_id": str(turn.id),
                    "round": room.current_round,
                    "agent_id": str(speaker.id),
                    "agent_name": speaker.agent_profile.name,
                },
            )
            room.save(update_fields=["event_sequence", "updated_at"])
            envelopes = [_event_envelope(room_event) for room_event in [*pending_events, event]]
            _broadcast_after_commit(room.id, envelopes)
            return room.current_round, TurnSerializer(turn).data, envelopes

        if not RoomEvent.objects.filter(
            roundtable=room,
            event_type=p.ROUND_COMPLETED,
            payload__round=room.current_round,
        ).exists():
            completed_round = room.current_round
            created = [
                *pending_events,
                _append_room_event(
                    room,
                    p.ROUND_COMPLETED,
                    {"round": completed_round},
                ),
            ]
            if completed_round < room.max_rounds:
                reason = _budget_exhaustion_reason(room)
                if reason is not None:
                    room.status = Roundtable.Status.COMPLETED
                    room.budget_exhausted_reason = reason
                    created.append(
                        _append_room_event(
                            room,
                            p.ROOM_BUDGET_EXHAUSTED,
                            _budget_exhausted_payload(room, reason),
                        )
                    )
                    room.save(
                        update_fields=[
                            "status",
                            "budget_exhausted_reason",
                            "event_sequence",
                            "updated_at",
                        ]
                    )
                    envelopes = [_event_envelope(event) for event in created]
                    _broadcast_after_commit(room.id, envelopes)
                    return completed_round, None, envelopes

                room.current_round = completed_round + 1
                for agent in agents:
                    agent.state = RoundtableAgent.State.WAITING
                preferred_ids = _preferred_agent_ids(room, agents)
                speaker = select_next_speaker(agents, preferred_ids)
                if speaker is None:
                    raise RuntimeError("A roundtable must have a participant.")
                speaker.state = RoundtableAgent.State.THINKING
                RoundtableAgent.objects.bulk_update(agents, ["state"])
                turn = Turn.objects.create(
                    id=uuid.uuid4(),
                    roundtable=room,
                    roundtable_agent=speaker,
                    round_number=room.current_round,
                    deadline_at=now + timedelta(seconds=MAX_TURN_SECONDS),
                )
                created.extend(
                    [
                        _append_room_event(
                            room,
                            p.ROUND_STARTED,
                            {
                                "round": room.current_round,
                                "max_rounds": room.max_rounds,
                                "topic": room.topic,
                            },
                        ),
                        _append_room_event(
                            room,
                            p.AGENT_THINKING,
                            {
                                "turn_id": str(turn.id),
                                "round": room.current_round,
                                "agent_id": str(speaker.id),
                                "agent_name": speaker.agent_profile.name,
                            },
                        ),
                    ]
                )
                room.status = Roundtable.Status.RUNNING
                room.save(
                    update_fields=[
                        "current_round",
                        "status",
                        "event_sequence",
                        "updated_at",
                    ]
                )
                envelopes = [_event_envelope(event) for event in created]
                _broadcast_after_commit(room.id, envelopes)
                return room.current_round, TurnSerializer(turn).data, envelopes

            room.status = Roundtable.Status.SUMMARIZING
            created.append(
                _append_room_event(
                    room,
                    p.SUMMARY_STARTED,
                    {"round": completed_round},
                )
            )
            room.save(update_fields=["status", "event_sequence", "updated_at"])
            envelopes = [_event_envelope(event) for event in created]
            _broadcast_after_commit(room.id, envelopes)
            return completed_round, None, envelopes

        return room.current_round, None, []


def pass_turn(
    roundtable_id: str,
    guest_session_id: str,
    turn_id: str,
    roundtable_agent_id: str,
    usage: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Mark the scheduled Agent as having reviewed the discussion and passed."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status not in AGENT_SPEAKING_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能提交 pass。"})
        turn = (
            Turn.objects.select_for_update()
            .select_related("roundtable_agent__agent_profile")
            .filter(id=turn_id, roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        if turn is None:
            raise ValidationError({"turn_id": "turn 已过期、重复或不属于当前圆桌。"})
        agent = turn.roundtable_agent
        if str(agent.id) != roundtable_agent_id:
            raise ValidationError({"roundtable_agent_id": "提交者不是当前 turn 的发言人。"})

        _record_usage(turn, usage)
        turn.status = Turn.Status.PASSED
        turn.completed_at = timezone.now()
        turn.save(update_fields=["status", "completed_at"])
        agent.state = RoundtableAgent.State.PASSED
        agent.save(update_fields=["state"])
        pass_event = _append_room_event(
            room,
            p.AGENT_PASSED,
            {
                "turn_id": str(turn.id),
                "round": turn.round_number,
                "agent_id": str(agent.id),
                "agent_name": agent.agent_profile.name,
            },
        )
        events = [pass_event]
        if room.pause_pending:
            room.status = Roundtable.Status.PAUSED
            room.pause_pending = False
            events.append(
                _append_room_event(
                    room,
                    p.ROOM_PAUSED,
                    {"status": Roundtable.Status.PAUSED},
                )
            )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelopes = [_event_envelope(event) for event in events]
        _broadcast_after_commit(room.id, envelopes)
        return envelopes[0]


def fail_turn(
    roundtable_id: str,
    guest_session_id: str,
    command: TurnFailureCommand,
) -> dict[str, Any] | None:
    """Close one scheduled turn as failed without discarding prior messages."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None:
            return None
        if room.status not in AGENT_SPEAKING_STATUSES:
            raise ValidationError({"status": "圆桌当前状态不能提交失败。"})

        turn = (
            Turn.objects.select_for_update()
            .select_related("roundtable_agent__agent_profile")
            .filter(id=command.turn_id, roundtable=room, status=Turn.Status.PENDING)
            .first()
        )
        if turn is None:
            raise ValidationError({"turn_id": "turn 已过期、重复或不属于当前圆桌。"})
        agent = turn.roundtable_agent
        if str(agent.id) != command.roundtable_agent_id:
            raise ValidationError({"roundtable_agent_id": "提交者不是当前 turn 的发言人。"})

        turn.status = Turn.Status.FAILED
        turn.failure_code = command.failure_code
        turn.failure_message = command.message
        turn.failure_partial = command.partial
        turn.retryable = command.retryable
        turn.completed_at = timezone.now()
        turn.save(
            update_fields=[
                "status",
                "failure_code",
                "failure_message",
                "failure_partial",
                "retryable",
                "completed_at",
            ]
        )
        _record_usage(turn, command.usage, failure_code=command.failure_code)
        agent.state = RoundtableAgent.State.FAILED
        agent.save(update_fields=["state"])
        failure_event = _append_room_event(
            room,
            p.AGENT_FAILED,
            _turn_failure_payload(turn),
        )
        events = [failure_event]
        if room.pause_pending:
            room.status = Roundtable.Status.PAUSED
            room.pause_pending = False
            events.append(
                _append_room_event(
                    room,
                    p.ROOM_PAUSED,
                    {"status": Roundtable.Status.PAUSED},
                )
            )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelopes = [_event_envelope(event) for event in events]
        _broadcast_after_commit(room.id, envelopes)
        return envelopes[0]


room_access_allowed = database_sync_to_async(_room_access_allowed)
join_snapshot = database_sync_to_async(_join_snapshot)
events_after = database_sync_to_async(_events_after)
run_mock_round = database_sync_to_async(_run_mock_round)
