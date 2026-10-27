"""End-to-end WebSocket tests: join, mock round trip, cursor replay."""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta

import pytest
from asgiref.sync import sync_to_async
from channels.layers import get_channel_layer
from channels.testing import WebsocketCommunicator
from django.test import override_settings
from django.utils import timezone

from apps.roundtables import consumers as consumer_module
from apps.roundtables import protocol as p
from apps.roundtables.budget import MAX_DISCUSSION_SECONDS
from apps.roundtables.models import (
    GuestSession,
    Message,
    RoomEvent,
    Roundtable,
    RoundtableAgent,
)
from apps.roundtables.tests.factories import create_presets
from roundtable.asgi import application

pytestmark = pytest.mark.django_db(transaction=True)

TOPIC = "该不该把验证周期压缩到两周？"

MOCK_ROUND_TYPES = (
    ["round.started"]
    + [
        "agent.thinking",
        "agent.typing",
        "message.completed",
    ]
    * 3
    + ["round.completed"]
)
MOCK_ROUND_LENGTH = len(MOCK_ROUND_TYPES)
MOCK_SUMMARY_ROUND_LENGTH = MOCK_ROUND_LENGTH + 1


def _seed_room() -> tuple[str, str]:
    session = GuestSession.objects.create(id=uuid.uuid4())
    profiles = create_presets()
    room = Roundtable.objects.create(id=uuid.uuid4(), guest_session=session, topic=TOPIC)
    for position, profile in enumerate(profiles):
        RoundtableAgent.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            agent_profile=profile,
            position=position,
        )
    return str(session.id), str(room.id)


async def _connect(session_id: str, room_id: str, cursor: int | None = None):
    query = f"?guest_session={session_id}"
    if cursor is not None:
        query += f"&cursor={cursor}"
    communicator = WebsocketCommunicator(application, f"/ws/v1/roundtables/{room_id}/{query}")
    connected, _ = await communicator.connect()
    return communicator, connected


async def test_join_returns_empty_room_with_three_participants():
    session_id, room_id = await sync_to_async(_seed_room)()
    communicator, connected = await _connect(session_id, room_id)

    assert connected
    joined = await communicator.receive_json_from(timeout=1)

    assert joined["event_type"] == "room.joined"
    assert joined["room_id"] == room_id
    assert joined["sequence"] == 0, "joined is ephemeral and must not move the cursor"
    assert joined["payload"]["messages"] == []
    snapshot = joined["payload"]["roundtable"]
    assert snapshot["id"] == room_id
    assert snapshot["status"] == "ready"
    assert [p["agent"]["key"] for p in snapshot["participants"]] == [
        "advocate",
        "skeptic",
        "experience",
    ]
    await communicator.disconnect()


async def test_mock_run_completes_one_round_trip():
    session_id, room_id = await sync_to_async(_seed_room)()
    communicator, _ = await _connect(session_id, room_id)
    await communicator.receive_json_from(timeout=1)

    await communicator.send_json_to({"event_type": "mock.run"})
    events = [await communicator.receive_json_from(timeout=2) for _ in range(MOCK_ROUND_LENGTH)]

    assert [event["event_type"] for event in events] == MOCK_ROUND_TYPES
    assert [event["sequence"] for event in events] == list(range(1, MOCK_ROUND_LENGTH + 1))
    assert all(event["room_id"] == room_id for event in events)
    assert all(event["event_id"] for event in events)
    assert all(event["created_at"].endswith("Z") for event in events)

    messages = [
        event["payload"]["message"]
        for event in events
        if event["event_type"] == "message.completed"
    ]
    assert [message["author"]["agent_key"] for message in messages] == [
        "advocate",
        "skeptic",
        "experience",
    ]
    assert messages[0]["message_type"] == "proposal"
    assert messages[0]["stance"] is None
    assert messages[1]["message_type"] == "challenge"
    assert messages[1]["stance"] == "challenge"
    assert messages[1]["references"] == [messages[0]["id"]]
    assert messages[2]["stance"] == "supplement"

    stored = await sync_to_async(RoomEvent.objects.filter(roundtable_id=room_id).count)()
    assert stored == MOCK_ROUND_LENGTH
    room = await sync_to_async(Roundtable.objects.get)(id=room_id)
    assert room.current_round == 1
    assert room.status == Roundtable.Status.RUNNING
    states = await sync_to_async(
        lambda: list(
            RoundtableAgent.objects.filter(roundtable_id=room_id).values_list("state", flat=True)
        )
    )()
    assert states == ["completed", "completed", "completed"]
    await communicator.disconnect()


async def test_mock_budget_stops_after_two_rounds():
    session_id, room_id = await sync_to_async(_seed_room)()
    communicator, _ = await _connect(session_id, room_id)
    await communicator.receive_json_from(timeout=1)

    for round_number, length in ((1, MOCK_ROUND_LENGTH), (2, MOCK_SUMMARY_ROUND_LENGTH)):
        await communicator.send_json_to({"event_type": "mock.run"})
        events = [await communicator.receive_json_from(timeout=2) for _ in range(length)]
        assert events[-1]["payload"]["round"] == round_number

    await communicator.send_json_to({"event_type": "mock.run"})
    assert await communicator.receive_nothing(timeout=0.3)

    room = await sync_to_async(Roundtable.objects.get)(id=room_id)
    assert room.current_round == 2
    assert room.status == Roundtable.Status.SUMMARIZING
    await communicator.disconnect()


async def test_mock_run_respects_the_discussion_time_budget_once():
    session_id, room_id = await sync_to_async(_seed_room)()
    await sync_to_async(Roundtable.objects.filter(id=room_id).update)(
        started_at=timezone.now() - timedelta(seconds=MAX_DISCUSSION_SECONDS + 1)
    )
    communicator, _ = await _connect(session_id, room_id)
    await communicator.receive_json_from(timeout=1)

    await communicator.send_json_to({"event_type": "mock.run"})
    event = await communicator.receive_json_from(timeout=2)

    assert event["event_type"] == "budget.exhausted"
    assert event["payload"]["reason"] == "duration"
    await communicator.send_json_to({"event_type": "mock.run"})
    assert await communicator.receive_nothing(timeout=0.3)
    room = await sync_to_async(Roundtable.objects.get)(id=room_id)
    assert room.status == Roundtable.Status.COMPLETED
    assert (
        await sync_to_async(lambda: room.events.filter(event_type="budget.exhausted").count())()
        == 1
    )
    await communicator.disconnect()


async def test_reconnect_replays_events_after_cursor():
    session_id, room_id = await sync_to_async(_seed_room)()

    first, _ = await _connect(session_id, room_id)
    await first.receive_json_from(timeout=1)
    await first.send_json_to({"event_type": "mock.run"})
    for _ in range(MOCK_ROUND_LENGTH):
        await first.receive_json_from(timeout=2)
    await first.disconnect()

    second, _ = await _connect(session_id, room_id, cursor=5)
    joined = await second.receive_json_from(timeout=1)
    assert joined["event_type"] == "room.joined"
    assert len(joined["payload"]["messages"]) == 3
    assert joined["payload"]["replay"] == {
        "requested_cursor": 5,
        "oldest_sequence": 1,
        "latest_sequence": MOCK_ROUND_LENGTH,
        "window_days": 90,
        "cursor_expired": False,
    }
    replayed = [await second.receive_json_from(timeout=2) for _ in range(MOCK_ROUND_LENGTH - 5)]
    assert [event["sequence"] for event in replayed] == list(range(6, MOCK_ROUND_LENGTH + 1))
    assert await second.receive_nothing(timeout=0.3)
    await second.disconnect()


@override_settings(ROOM_EVENT_REPLAY_WINDOW_DAYS=1)
async def test_expired_cursor_returns_snapshot_reset_without_partial_replay():
    session_id, room_id = await sync_to_async(_seed_room)()
    message_id = uuid.uuid4()
    await sync_to_async(Message.objects.create)(
        id=message_id,
        roundtable_id=room_id,
        author_type=Message.AuthorType.USER,
        round_number=0,
        message_type=Message.Type.USER_MESSAGE,
        body="窗口外仍应出现在完整快照里。",
    )

    first, _ = await _connect(session_id, room_id)
    await first.receive_json_from(timeout=1)
    await first.send_json_to({"event_type": "mock.run"})
    for _ in range(MOCK_ROUND_LENGTH):
        await first.receive_json_from(timeout=2)
    await first.disconnect()

    cutoff = timezone.now() - timedelta(days=2)
    await sync_to_async(RoomEvent.objects.filter(roundtable_id=room_id, sequence__lte=5).update)(
        created_at=cutoff
    )

    second, _ = await _connect(session_id, room_id, cursor=0)
    joined = await second.receive_json_from(timeout=1)

    assert joined["payload"]["replay"] == {
        "requested_cursor": 0,
        "oldest_sequence": 6,
        "latest_sequence": MOCK_ROUND_LENGTH,
        "window_days": 1,
        "cursor_expired": True,
    }
    restored_message_ids = [message["id"] for message in joined["payload"]["messages"]]
    assert str(message_id) in restored_message_ids
    assert len(restored_message_ids) == 4
    assert await second.receive_nothing(timeout=0.3)
    await second.disconnect()


async def test_live_events_wait_for_replay_to_finish(monkeypatch):
    session_id, room_id = await sync_to_async(_seed_room)()
    replayed = [
        p.make_envelope(
            event_id=str(uuid.uuid4()),
            room_id=room_id,
            sequence=sequence,
            event_type="future.replayed",
            payload={"sequence": sequence},
        )
        for sequence in (1, 2)
    ]
    live = p.make_envelope(
        event_id=str(uuid.uuid4()),
        room_id=room_id,
        sequence=3,
        event_type="future.live",
        payload={"sequence": 3},
    )
    entered_replay = asyncio.Event()
    release_replay = asyncio.Event()

    async def blocked_replay(*_args):
        entered_replay.set()
        await release_replay.wait()
        return replayed

    monkeypatch.setattr(consumer_module, "events_after", blocked_replay)
    communicator = WebsocketCommunicator(
        application,
        f"/ws/v1/roundtables/{room_id}/?guest_session={session_id}&cursor=0",
    )
    connect_task = asyncio.create_task(communicator.connect())

    await asyncio.wait_for(entered_replay.wait(), timeout=1)
    await get_channel_layer().group_send(
        f"room.{room_id}",
        {"type": "room.event", "envelope": live},
    )
    await asyncio.sleep(0.05)
    release_replay.set()
    connected, _ = await asyncio.wait_for(connect_task, timeout=1)

    assert connected
    first = await communicator.receive_json_from(timeout=1)
    remaining = [await communicator.receive_json_from(timeout=1) for _ in range(3)]
    assert first["event_type"] == "room.joined"
    assert [event["sequence"] for event in remaining] == [1, 2, 3]
    await communicator.disconnect()


async def test_live_event_during_snapshot_build_is_not_lost(monkeypatch):
    session_id, room_id = await sync_to_async(_seed_room)()
    snapshot = p.make_envelope(
        event_id=str(uuid.uuid4()),
        room_id=room_id,
        sequence=0,
        event_type=p.ROOM_JOINED,
        payload={
            "roundtable": {"id": room_id, "last_sequence": 0},
            "messages": [],
            "failures": [],
            "replay": {
                "requested_cursor": 0,
                "oldest_sequence": None,
                "latest_sequence": 0,
                "window_days": 90,
                "cursor_expired": True,
            },
        },
    )
    live = p.make_envelope(
        event_id=str(uuid.uuid4()),
        room_id=room_id,
        sequence=1,
        event_type="future.live",
        payload={"sequence": 1},
    )
    entered_snapshot = asyncio.Event()
    release_snapshot = asyncio.Event()

    async def blocked_snapshot(*_args):
        entered_snapshot.set()
        await release_snapshot.wait()
        return snapshot

    monkeypatch.setattr(consumer_module, "join_snapshot", blocked_snapshot)
    communicator = WebsocketCommunicator(
        application,
        f"/ws/v1/roundtables/{room_id}/?guest_session={session_id}&cursor=0",
    )
    connect_task = asyncio.create_task(communicator.connect())

    await asyncio.wait_for(entered_snapshot.wait(), timeout=1)
    await get_channel_layer().group_send(
        f"room.{room_id}",
        {"type": "room.event", "envelope": live},
    )
    release_snapshot.set()
    connected, _ = await asyncio.wait_for(connect_task, timeout=1)

    assert connected
    first = await communicator.receive_json_from(timeout=1)
    second = await communicator.receive_json_from(timeout=1)
    assert first["event_type"] == p.ROOM_JOINED
    assert second["event_id"] == live["event_id"]
    await communicator.disconnect()


async def test_connection_without_guest_session_is_rejected():
    _, room_id = await sync_to_async(_seed_room)()
    communicator = WebsocketCommunicator(application, f"/ws/v1/roundtables/{room_id}/")
    connected, _ = await communicator.connect()

    assert connected is False


async def test_malformed_guest_session_is_rejected():
    _, room_id = await sync_to_async(_seed_room)()
    communicator = WebsocketCommunicator(
        application, f"/ws/v1/roundtables/{room_id}/?guest_session=not-a-uuid"
    )

    connected, _ = await communicator.connect()

    assert connected is False


async def test_malformed_room_id_is_rejected():
    session_id, _ = await sync_to_async(_seed_room)()
    communicator = WebsocketCommunicator(
        application,
        f"/ws/v1/roundtables/{'-' * 36}/?guest_session={session_id}",
    )

    connected, _ = await communicator.connect()

    assert connected is False


async def test_connection_with_other_guest_session_is_rejected():
    _, room_id = await sync_to_async(_seed_room)()
    other_session = await sync_to_async(GuestSession.objects.create)(id=uuid.uuid4())
    communicator, connected = await _connect(str(other_session.id), room_id)

    assert connected is False


async def test_invalid_cursor_is_rejected():
    session_id, room_id = await sync_to_async(_seed_room)()
    communicator, connected = await _connect(session_id, room_id, cursor=-1)

    assert connected is False


async def test_unknown_client_command_is_ignored():
    session_id, room_id = await sync_to_async(_seed_room)()
    communicator, _ = await _connect(session_id, room_id)
    await communicator.receive_json_from(timeout=1)

    await communicator.send_json_to({"event_type": "room.teleport"})
    assert await communicator.receive_nothing(timeout=0.3)

    await communicator.send_json_to({"event_type": "mock.run"})
    first = await communicator.receive_json_from(timeout=2)
    assert first["event_type"] == "round.started"
    await communicator.disconnect()
