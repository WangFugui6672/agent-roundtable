"""Database-facing services used by both REST views and the WS consumer."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from apps.roundtables import mock
from apps.roundtables import protocol as p
from apps.roundtables.message_validation import validate_agent_message
from apps.roundtables.models import Message, RoomEvent, Roundtable, RoundtableAgent, Turn
from apps.roundtables.scheduler import select_next_speaker
from apps.roundtables.serializers import MessageSerializer, RoundtableSerializer, TurnSerializer


@dataclass(frozen=True)
class RoomCommandResult:
    room: Roundtable
    events: list[dict[str, Any]]


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


def _room_for_session(roundtable_id: str, guest_session_id: str) -> Roundtable | None:
    return (
        Roundtable.objects.filter(id=roundtable_id, guest_session_id=guest_session_id)
        .prefetch_related("agents__agent_profile")
        .first()
    )


def build_join_envelope(room: Roundtable) -> dict[str, Any]:
    """``room.joined`` is an ephemeral snapshot, so its sequence stays 0."""
    messages = (
        room.messages.select_related("roundtable_agent__agent_profile")
        .prefetch_related("references")
        .all()
    )
    return p.make_envelope(
        event_id=p.new_event_id(),
        room_id=str(room.id),
        sequence=p.EPHEMERAL_SEQUENCE,
        event_type=p.ROOM_JOINED,
        payload={
            "roundtable": RoundtableSerializer(room).data,
            "messages": MessageSerializer(messages, many=True).data,
        },
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


def _join_snapshot(roundtable_id: str, guest_session_id: str) -> dict[str, Any] | None:
    room = _room_for_session(roundtable_id, guest_session_id)
    if room is None:
        return None
    return build_join_envelope(room)


def _events_after(roundtable_id: str, guest_session_id: str, cursor: int) -> list[dict[str, Any]]:
    if _room_for_session(roundtable_id, guest_session_id) is None:
        return []
    events = RoomEvent.objects.filter(roundtable_id=roundtable_id, sequence__gt=cursor).order_by(
        "sequence"
    )
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
            or room.status not in {Roundtable.Status.READY, Roundtable.Status.RUNNING}
            or room.current_round >= room.max_rounds
        ):
            return []

        agents = list(room.agents.select_related("agent_profile").order_by("position"))
        round_number = room.current_round + 1
        script = mock.build_mock_round(room, agents, round_number)

        agents_by_id = {str(agent.id): agent for agent in agents}
        created: list[RoomEvent] = []
        for event_type, payload in script:
            if event_type == p.ROUND_STARTED:
                for agent in agents:
                    agent.state = RoundtableAgent.State.WAITING
            elif event_type == p.AGENT_THINKING:
                agents_by_id[payload["agent_id"]].state = RoundtableAgent.State.THINKING
            elif event_type == p.AGENT_TYPING:
                agents_by_id[payload["agent_id"]].state = RoundtableAgent.State.TYPING
            elif event_type == p.MESSAGE_COMPLETED:
                author_id = payload["message"]["author"]["roundtable_agent_id"]
                agents_by_id[author_id].state = RoundtableAgent.State.COMPLETED

            created.append(_append_room_event(room, event_type, payload))

        RoundtableAgent.objects.bulk_update(agents, ["state"])

        room.current_round = round_number
        room.status = (
            Roundtable.Status.COMPLETED
            if round_number >= room.max_rounds
            else Roundtable.Status.RUNNING
        )
        room.save(update_fields=["current_round", "status", "event_sequence", "updated_at"])

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
        if room.status in {
            Roundtable.Status.SUMMARIZING,
            Roundtable.Status.COMPLETED,
            Roundtable.Status.FAILED,
            Roundtable.Status.ARCHIVED,
        }:
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
        if room.status in {
            Roundtable.Status.SUMMARIZING,
            Roundtable.Status.COMPLETED,
            Roundtable.Status.FAILED,
            Roundtable.Status.ARCHIVED,
        }:
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
        if room.status in {
            Roundtable.Status.SUMMARIZING,
            Roundtable.Status.COMPLETED,
            Roundtable.Status.FAILED,
            Roundtable.Status.ARCHIVED,
        }:
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
        if room.status == Roundtable.Status.COMPLETED:
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

        # Issue #9 can route this boundary through summarizing before completion.
        room.status = Roundtable.Status.COMPLETED
        room.pause_pending = False
        event = _append_room_event(
            room,
            p.ROOM_ENDED,
            {
                "status": Roundtable.Status.COMPLETED,
                "cancelled_turn_id": cancelled_turn_id,
                "cancelled_agent_id": cancelled_agent_id,
            },
        )
        room.save(update_fields=["status", "pause_pending", "event_sequence", "updated_at"])
        envelope = _event_envelope(event)
        _broadcast_after_commit(room.id, [envelope])
        return RoomCommandResult(room=room, events=[envelope])


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
        if room.status not in {Roundtable.Status.READY, Roundtable.Status.RUNNING}:
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
        )
        message.references.set(validated.get("references") or [])

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
        if (
            room.status == Roundtable.Status.COMPLETED
            and RoomEvent.objects.filter(
                roundtable=room,
                event_type=p.ROUND_COMPLETED,
                payload__round=room.current_round,
            ).exists()
        ):
            return room.current_round, None, []
        if room.status == Roundtable.Status.COMPLETED:
            raise ValidationError({"status": "圆桌当前状态不能签发新的 turn。"})
        if room.status in {
            Roundtable.Status.PAUSED,
            Roundtable.Status.SUMMARIZING,
            Roundtable.Status.FAILED,
            Roundtable.Status.ARCHIVED,
        }:
            raise ValidationError({"status": "圆桌当前状态不能签发新的 turn。"})

        agents = list(
            RoundtableAgent.objects.select_for_update()
            .filter(roundtable=room)
            .select_related("agent_profile")
            .order_by("position")
        )
        preferred_ids = _preferred_agent_ids(room, agents)
        if room.current_round == 0:
            room.current_round = 1
            room.status = Roundtable.Status.RUNNING
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
            room.save(update_fields=["current_round", "status", "event_sequence", "updated_at"])
            envelopes = [_event_envelope(event) for event in created]
            _broadcast_after_commit(room.id, envelopes)
            return 1, TurnSerializer(turn).data, envelopes

        active_turn = (
            Turn.objects.select_for_update()
            .filter(roundtable=room, status=Turn.Status.PENDING)
            .select_related("roundtable_agent__agent_profile")
            .first()
        )
        if active_turn is not None:
            return room.current_round, TurnSerializer(active_turn).data, []

        speaker = select_next_speaker(agents, preferred_ids)
        if speaker is not None:
            speaker.state = RoundtableAgent.State.THINKING
            speaker.save(update_fields=["state"])
            turn = Turn.objects.create(
                id=uuid.uuid4(),
                roundtable=room,
                roundtable_agent=speaker,
                round_number=room.current_round,
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
            envelope = _event_envelope(event)
            _broadcast_after_commit(room.id, [envelope])
            return room.current_round, TurnSerializer(turn).data, [envelope]

        if not RoomEvent.objects.filter(
            roundtable=room,
            event_type=p.ROUND_COMPLETED,
            payload__round=room.current_round,
        ).exists():
            completed_round = room.current_round
            created = [
                _append_room_event(
                    room,
                    p.ROUND_COMPLETED,
                    {"round": completed_round},
                )
            ]
            if completed_round < room.max_rounds:
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

            room.status = Roundtable.Status.COMPLETED
            room.save(update_fields=["status", "event_sequence", "updated_at"])
            envelope = _event_envelope(created[0])
            _broadcast_after_commit(room.id, [envelope])
            return completed_round, None, [envelope]

        return room.current_round, None, []


def pass_turn(
    roundtable_id: str,
    guest_session_id: str,
    turn_id: str,
    roundtable_agent_id: str,
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
        if room.status not in {Roundtable.Status.READY, Roundtable.Status.RUNNING}:
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


join_snapshot = database_sync_to_async(_join_snapshot)
events_after = database_sync_to_async(_events_after)
run_mock_round = database_sync_to_async(_run_mock_round)
