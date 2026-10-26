"""Database-facing services used by both REST views and the WS consumer."""

from __future__ import annotations

import uuid
from typing import Any

from channels.db import database_sync_to_async
from django.db import transaction

from apps.roundtables import mock
from apps.roundtables import protocol as p
from apps.roundtables.models import RoomEvent, Roundtable, RoundtableAgent
from apps.roundtables.serializers import RoundtableSerializer


def _event_envelope(event: RoomEvent) -> dict[str, Any]:
    return p.make_envelope(
        event_id=str(event.id),
        room_id=str(event.roundtable_id),
        sequence=event.sequence,
        event_type=event.event_type,
        payload=event.payload,
        created_at=p.iso8601_millis(event.created_at),
    )


def _room_for_session(roundtable_id: str, guest_session_id: str) -> Roundtable | None:
    return (
        Roundtable.objects.filter(id=roundtable_id, guest_session_id=guest_session_id)
        .prefetch_related("agents__agent_profile")
        .first()
    )


def build_join_envelope(room: Roundtable) -> dict[str, Any]:
    """``room.joined`` is an ephemeral snapshot, so its sequence stays 0."""
    return p.make_envelope(
        event_id=p.new_event_id(),
        room_id=str(room.id),
        sequence=p.EPHEMERAL_SEQUENCE,
        event_type=p.ROOM_JOINED,
        payload={"roundtable": RoundtableSerializer(room).data, "messages": []},
    )


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


def _run_mock_round(roundtable_id: str, guest_session_id: str) -> list[dict[str, Any]]:
    """Persist and return the next scripted mock round, if the budget allows it."""
    with transaction.atomic():
        room = (
            Roundtable.objects.select_for_update()
            .filter(id=roundtable_id, guest_session_id=guest_session_id)
            .first()
        )
        if room is None or room.current_round >= room.max_rounds:
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

            room.event_sequence += 1
            created.append(
                RoomEvent.objects.create(
                    id=uuid.uuid4(),
                    roundtable=room,
                    sequence=room.event_sequence,
                    event_type=event_type,
                    payload=payload,
                )
            )

        RoundtableAgent.objects.bulk_update(agents, ["state"])

        room.current_round = round_number
        room.status = (
            Roundtable.Status.COMPLETED
            if round_number >= room.max_rounds
            else Roundtable.Status.RUNNING
        )
        room.save(update_fields=["current_round", "status", "event_sequence", "updated_at"])

        return [_event_envelope(event) for event in created]


join_snapshot = database_sync_to_async(_join_snapshot)
events_after = database_sync_to_async(_events_after)
run_mock_round = database_sync_to_async(_run_mock_round)
