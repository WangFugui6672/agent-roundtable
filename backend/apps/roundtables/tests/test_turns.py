"""First-round scheduling contract (Issue #5, docs/protocol.md)."""

from __future__ import annotations

import uuid

import pytest
from asgiref.sync import sync_to_async
from channels.testing import WebsocketCommunicator

from apps.roundtables.models import (
    GuestSession,
    Message,
    RoomEvent,
    Roundtable,
    RoundtableAgent,
    Turn,
)
from apps.roundtables.tests.factories import create_presets
from roundtable.asgi import application

pytestmark = pytest.mark.django_db

TOPIC = "该不该把验证周期压缩到两周？"


def make_room() -> Roundtable:
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(id=uuid.uuid4(), guest_session=session, topic=TOPIC)
    for position, profile in enumerate(create_presets()):
        RoundtableAgent.objects.create(
            id=uuid.uuid4(), roundtable=room, agent_profile=profile, position=position
        )
    return room


def request_next_turn(api_client, room: Roundtable):
    return api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )


def test_next_turn_starts_round_and_assigns_the_first_speaker(api_client):
    room = make_room()
    first_agent = room.agents.order_by("position").first()

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    body = response.json()
    assert body["round"] == 1
    turn = body["turn"]
    turn_id = uuid.UUID(turn["turn_id"])
    assert turn == {
        "turn_id": str(turn_id),
        "round": 1,
        "roundtable_agent_id": str(first_agent.id),
        "position": 0,
        "agent_key": "advocate",
        "agent_name": "方案派",
    }
    assert [event["event_type"] for event in body["events"]] == [
        "round.started",
        "agent.thinking",
    ]
    assert body["events"][1]["payload"] == {
        "turn_id": str(turn_id),
        "round": 1,
        "agent_id": str(first_agent.id),
        "agent_name": "方案派",
    }

    room.refresh_from_db()
    first_agent.refresh_from_db()
    assert room.current_round == 1
    assert room.status == Roundtable.Status.RUNNING
    assert first_agent.state == RoundtableAgent.State.THINKING
    stored_turn = Turn.objects.get(id=turn_id)
    assert stored_turn.roundtable == room
    assert stored_turn.roundtable_agent == first_agent
    assert stored_turn.round_number == 1
    assert stored_turn.status == Turn.Status.PENDING


def test_repeated_next_turn_reuses_the_active_speaker(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()

    repeated = request_next_turn(api_client, room)

    assert repeated.status_code == 200
    assert repeated.json()["turn"] == first["turn"]
    assert repeated.json()["events"] == []
    assert (
        RoundtableAgent.objects.filter(
            roundtable=room, state=RoundtableAgent.State.THINKING
        ).count()
        == 1
    )


def test_roundtable_snapshot_exposes_the_pending_turn_for_recovery(api_client):
    room = make_room()
    turn = request_next_turn(api_client, room).json()["turn"]

    response = api_client.get(
        f"/api/v1/roundtables/{room.id}",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 200
    assert response.json()["active_turn"] == turn


def test_next_turn_advances_to_the_next_agent_after_a_message(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做一个两周实验。",
            "body": "先做一个两周实验，再根据结果决定是否继续投入。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    body = response.json()
    assert body["turn"]["position"] == 1
    assert body["turn"]["agent_key"] == "skeptic"
    assert [event["event_type"] for event in body["events"]] == ["agent.thinking"]
    assert body["events"][0]["sequence"] == 4
    assert (
        RoundtableAgent.objects.filter(
            roundtable=room, state=RoundtableAgent.State.THINKING
        ).count()
        == 1
    )


def test_only_the_scheduled_agent_can_submit_a_message(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    second_agent = room.agents.order_by("position")[1]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": str(second_agent.id),
            "message_type": "challenge",
            "claim": "不应接受的并发发言。",
            "body": "此刻还没有轮到我发言。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "roundtable_agent_id" in response.json()["error"]["details"]
    assert Message.objects.filter(roundtable=room).count() == 0


def test_agent_message_requires_a_current_turn_even_before_the_round_starts(api_client):
    room = make_room()
    first_agent = room.agents.order_by("position").first()

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "roundtable_agent_id": str(first_agent.id),
            "message_type": "proposal",
            "claim": "没有 turn 不能提交。",
            "body": "服务端必须先签发 turn。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "turn_id" in response.json()["error"]["details"]
    assert Message.objects.filter(roundtable=room).count() == 0


def test_completed_turn_cannot_be_reported_twice(api_client):
    room = make_room()
    turn = request_next_turn(api_client, room).json()["turn"]
    body = {
        "turn_id": turn["turn_id"],
        "roundtable_agent_id": turn["roundtable_agent_id"],
        "message_type": "proposal",
        "claim": "只应完成一次。",
        "body": "同一个 turn 不能被重复提交。",
    }
    first = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    repeated = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert first.status_code == 201
    assert repeated.status_code == 400
    assert "turn_id" in repeated.json()["error"]["details"]
    assert Message.objects.filter(roundtable=room).count() == 1
    assert RoomEvent.objects.filter(roundtable=room, event_type="message.completed").count() == 1
    assert Turn.objects.get(id=turn["turn_id"]).status == Turn.Status.COMPLETED


def test_scheduled_agent_can_explicitly_pass(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    event = response.json()
    assert event["sequence"] == 3
    assert event["event_type"] == "agent.passed"
    assert event["payload"] == {
        "turn_id": first["turn_id"],
        "round": 1,
        "agent_id": first["roundtable_agent_id"],
        "agent_name": "方案派",
    }
    agent = RoundtableAgent.objects.get(id=first["roundtable_agent_id"])
    assert agent.state == RoundtableAgent.State.PASSED
    assert Message.objects.filter(roundtable=room).count() == 0


def test_pass_is_recorded_once_for_the_current_turn(api_client):
    room = make_room()
    turn = request_next_turn(api_client, room).json()["turn"]
    body = {
        "turn_id": turn["turn_id"],
        "roundtable_agent_id": turn["roundtable_agent_id"],
    }

    first = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    repeated = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert first.status_code == 201
    assert repeated.status_code == 400
    assert RoomEvent.objects.filter(roundtable=room, event_type="agent.passed").count() == 1
    assert Message.objects.filter(roundtable=room).count() == 0
    assert Turn.objects.get(id=turn["turn_id"]).status == Turn.Status.PASSED


def test_first_round_automatically_starts_round_two(api_client):
    room = make_room()

    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做验证实验。",
            "body": "先做一个两周的验证实验。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    second = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": second["turn_id"],
            "roundtable_agent_id": second["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "需要先定义否证条件。",
            "body": "如果没有否证条件，两周实验只会确认已有偏见。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    third = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        {
            "turn_id": third["turn_id"],
            "roundtable_agent_id": third["roundtable_agent_id"],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    body = response.json()
    assert body["round"] == 2
    assert body["turn"]["round"] == 2
    assert [event["event_type"] for event in body["events"]] == [
        "round.completed",
        "round.started",
        "agent.thinking",
    ]
    assert [event["sequence"] for event in body["events"]] == [8, 9, 10]
    assert body["events"][0]["payload"] == {"round": 1}
    room.refresh_from_db()
    assert room.current_round == 2
    assert room.status == Roundtable.Status.RUNNING
    assert list(room.agents.values_list("state", flat=True)) == [
        RoundtableAgent.State.THINKING,
        RoundtableAgent.State.WAITING,
        RoundtableAgent.State.WAITING,
    ]
    assert Message.objects.filter(roundtable=room).count() == 2


@pytest.mark.django_db(transaction=True)
async def test_websocket_receives_the_first_round_in_scheduler_order(api_client):
    room = await sync_to_async(make_room)()
    communicator = WebsocketCommunicator(
        application,
        f"/ws/v1/roundtables/{room.id}/?guest_session={room.guest_session_id}",
    )
    connected, _ = await communicator.connect()
    assert connected
    await communicator.receive_json_from(timeout=1)

    first = await sync_to_async(request_next_turn)(api_client, room)
    start_events = [
        await communicator.receive_json_from(timeout=2),
        await communicator.receive_json_from(timeout=2),
    ]
    first_turn = first.json()["turn"]
    await sync_to_async(api_client.post)(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first_turn["turn_id"],
            "roundtable_agent_id": first_turn["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做验证实验。",
            "body": "先做一个两周的验证实验。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    first_message = await communicator.receive_json_from(timeout=2)

    second = await sync_to_async(request_next_turn)(api_client, room)
    second_thinking = await communicator.receive_json_from(timeout=2)
    second_turn = second.json()["turn"]
    await sync_to_async(api_client.post)(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": second_turn["turn_id"],
            "roundtable_agent_id": second_turn["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "需要先定义否证条件。",
            "body": "如果没有否证条件，两周实验只会确认已有偏见。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    second_message = await communicator.receive_json_from(timeout=2)

    third = await sync_to_async(request_next_turn)(api_client, room)
    third_thinking = await communicator.receive_json_from(timeout=2)
    third_turn = third.json()["turn"]
    await sync_to_async(api_client.post)(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        {
            "turn_id": third_turn["turn_id"],
            "roundtable_agent_id": third_turn["roundtable_agent_id"],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    passed = await communicator.receive_json_from(timeout=2)

    completed = await sync_to_async(request_next_turn)(api_client, room)
    round_completed = await communicator.receive_json_from(timeout=2)
    round_two_started = await communicator.receive_json_from(timeout=2)
    round_two_thinking = await communicator.receive_json_from(timeout=2)
    await communicator.disconnect()

    events = [
        *start_events,
        first_message,
        second_thinking,
        second_message,
        third_thinking,
        passed,
        round_completed,
        round_two_started,
        round_two_thinking,
    ]
    assert completed.json()["turn"]["round"] == 2
    assert [event["event_type"] for event in events] == [
        "round.started",
        "agent.thinking",
        "message.completed",
        "agent.thinking",
        "message.completed",
        "agent.thinking",
        "agent.passed",
        "round.completed",
        "round.started",
        "agent.thinking",
    ]
    assert [event["sequence"] for event in events] == list(range(1, 11))
    assert [
        event["payload"]["message"]["author"]["agent_key"]
        for event in events
        if event["event_type"] == "message.completed"
    ] == ["advocate", "skeptic"]
    assert [
        event["payload"]["turn_id"] for event in events if event["event_type"] == "agent.thinking"
    ] == [
        first_turn["turn_id"],
        second_turn["turn_id"],
        third_turn["turn_id"],
        completed.json()["turn"]["turn_id"],
    ]
    assert [
        event["payload"]["message"]["turn_id"]
        for event in events
        if event["event_type"] == "message.completed"
    ] == [first_turn["turn_id"], second_turn["turn_id"]]
    assert passed["payload"]["turn_id"] == third_turn["turn_id"]
