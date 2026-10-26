"""User intervention contract (Issue #6, docs/protocol.md)."""

from __future__ import annotations

import asyncio
import uuid

import pytest
from asgiref.sync import sync_to_async
from channels.testing import WebsocketCommunicator

from apps.roundtables.models import GuestSession, Message, Roundtable, RoundtableAgent, Turn
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


def send_user_message(api_client, room: Roundtable, body: str, **overrides):
    payload = {"body": body, **overrides}
    return api_client.post(
        f"/api/v1/roundtables/{room.id}/user-messages",
        payload,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )


def start_next_turn(api_client, room: Roundtable) -> dict:
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 200
    return response.json()["turn"]


def control(api_client, room: Roundtable, action: str):
    return api_client.post(
        f"/api/v1/roundtables/{room.id}/{action}",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )


def test_user_can_send_an_ordinary_group_message(api_client):
    room = make_room()

    response = send_user_message(api_client, room, "先补充一个约束：团队只有两个人。")

    assert response.status_code == 201
    body = response.json()
    assert body["roundtable"]["status"] == "paused"
    assert [event["event_type"] for event in body["events"]] == [
        "message.completed",
        "room.paused",
    ]
    message = body["events"][0]["payload"]["message"]
    assert message["author"] == {"type": "user", "name": "用户"}
    assert message["message_type"] == "user_message"
    assert message["claim"] is None
    assert message["body"] == "先补充一个约束：团队只有两个人。"
    assert message["turn_id"] is None
    assert message["mentioned_agent_ids"] == []

    stored = Message.objects.get(id=message["id"])
    assert stored.author_type == Message.AuthorType.USER
    assert stored.roundtable_agent is None
    assert stored.body == "先补充一个约束：团队只有两个人。"


def test_interjection_pauses_after_the_current_turn_finishes(api_client):
    room = make_room()
    turn = start_next_turn(api_client, room)

    interjection = send_user_message(api_client, room, "请先考虑只有两个人的团队。")

    assert interjection.status_code == 201
    interjection_body = interjection.json()
    assert interjection_body["roundtable"]["status"] == "running"
    assert interjection_body["roundtable"]["pause_pending"] is True
    assert [event["event_type"] for event in interjection_body["events"]] == [
        "message.completed",
        "room.pause_pending",
    ]

    completed = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做一个两周实验。",
            "body": "先做一个两周实验，再决定是否扩大范围。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert completed.status_code == 201
    room.refresh_from_db()
    assert room.status == Roundtable.Status.PAUSED
    assert room.pause_pending is False
    assert (
        Message.objects.filter(roundtable=room, author_type=Message.AuthorType.AGENT).count() == 1
    )
    assert list(room.events.values_list("event_type", flat=True))[-2:] == [
        "message.completed",
        "room.paused",
    ]


def test_pause_without_an_active_turn_is_direct_and_idempotent(api_client):
    room = make_room()

    first = control(api_client, room, "pause")
    repeated = control(api_client, room, "pause")

    assert first.status_code == 200
    assert first.json()["roundtable"]["status"] == "paused"
    assert [event["event_type"] for event in first.json()["events"]] == ["room.paused"]
    assert repeated.status_code == 200
    assert repeated.json()["roundtable"]["status"] == "paused"
    assert repeated.json()["events"] == []
    assert room.events.filter(event_type="room.paused").count() == 1


def test_explicit_pause_waits_for_the_active_turn(api_client):
    room = make_room()
    turn = start_next_turn(api_client, room)

    pending = control(api_client, room, "pause")
    repeated = control(api_client, room, "pause")

    assert pending.status_code == 200
    assert pending.json()["roundtable"]["pause_pending"] is True
    assert [event["event_type"] for event in pending.json()["events"]] == ["room.pause_pending"]
    assert repeated.json()["events"] == []

    completed = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先完成当前发言。",
            "body": "当前这条发言完成后暂停。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert completed.status_code == 201
    room.refresh_from_db()
    assert room.status == Roundtable.Status.PAUSED
    assert room.events.filter(event_type="room.pause_pending").count() == 1
    assert room.events.filter(event_type="room.paused").count() == 1


def test_resume_only_emits_once_per_transition(api_client):
    room = make_room()
    assert control(api_client, room, "pause").status_code == 200

    first = control(api_client, room, "resume")
    repeated = control(api_client, room, "resume")

    assert first.status_code == 200
    assert first.json()["roundtable"]["status"] == "running"
    assert [event["event_type"] for event in first.json()["events"]] == ["room.resumed"]
    assert repeated.status_code == 200
    assert repeated.json()["events"] == []
    assert room.events.filter(event_type="room.resumed").count() == 1


def test_end_cancels_the_pending_turn_and_blocks_late_reports(api_client):
    room = make_room()
    turn = start_next_turn(api_client, room)

    first = control(api_client, room, "end")
    repeated = control(api_client, room, "end")

    assert first.status_code == 200
    assert first.json()["roundtable"]["status"] == "completed"
    assert first.json()["roundtable"]["active_turn"] is None
    assert first.json()["roundtable"]["participants"][0]["state"] == "waiting"
    assert [event["event_type"] for event in first.json()["events"]] == ["room.ended"]
    assert first.json()["events"][0]["payload"] == {
        "status": "completed",
        "cancelled_turn_id": turn["turn_id"],
        "cancelled_agent_id": turn["roundtable_agent_id"],
    }
    assert repeated.status_code == 200
    assert repeated.json()["events"] == []
    assert Turn.objects.get(id=turn["turn_id"]).status == Turn.Status.CANCELLED

    late = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "迟到的回报不能写入。",
            "body": "圆桌已经结束。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert late.status_code == 400
    assert Message.objects.filter(roundtable=room).count() == 0


@pytest.mark.parametrize("action", ["pause", "end"])
def test_stopped_room_cannot_issue_a_new_turn(api_client, action):
    room = make_room()
    assert control(api_client, room, action).status_code == 200

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "status" in response.json()["error"]["details"]
    assert Turn.objects.filter(roundtable=room).count() == 0


def test_named_agent_is_scheduled_after_the_interjection(api_client):
    room = make_room()
    experience = room.agents.get(agent_profile__key="experience")
    advocate = room.agents.get(agent_profile__key="advocate")
    turn = start_next_turn(api_client, room)

    interjection = send_user_message(
        api_client,
        room,
        "体验派先回应一下：现有流程对用户有什么影响？",
        mentioned_agent_ids=[str(experience.id)],
    )
    assert interjection.status_code == 201
    assert interjection.json()["events"][0]["payload"]["message"]["mentioned_agent_ids"] == [
        str(experience.id)
    ]

    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": advocate.id,
            "message_type": "proposal",
            "claim": "先补齐当前方案。",
            "body": "先把当前方案的可执行步骤补齐。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert control(api_client, room, "resume").status_code == 200

    next_response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert next_response.status_code == 200
    assert next_response.json()["turn"]["roundtable_agent_id"] == str(experience.id)


def test_interjection_is_honored_when_the_current_agent_passes(api_client):
    room = make_room()
    turn = start_next_turn(api_client, room)
    assert send_user_message(api_client, room, "如果信息不足，可以跳过。").status_code == 201

    passed = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert passed.status_code == 201
    room.refresh_from_db()
    assert room.status == Roundtable.Status.PAUSED
    assert room.pause_pending is False
    assert list(room.events.values_list("event_type", flat=True))[-2:] == [
        "agent.passed",
        "room.paused",
    ]


def test_repeated_interjections_emit_pause_pending_only_once(api_client):
    room = make_room()
    start_next_turn(api_client, room)

    first = send_user_message(api_client, room, "第一条补充。")
    second = send_user_message(api_client, room, "第二条补充。")

    assert [event["event_type"] for event in first.json()["events"]] == [
        "message.completed",
        "room.pause_pending",
    ]
    assert [event["event_type"] for event in second.json()["events"]] == ["message.completed"]
    assert room.events.filter(event_type="room.pause_pending").count() == 1


def test_rejects_mentions_outside_the_roundtable(api_client):
    room = make_room()
    other_room = make_room()
    foreign_agent = other_room.agents.first()

    response = send_user_message(
        api_client,
        room,
        "这个 Agent 不应该被点名。",
        mentioned_agent_ids=[str(foreign_agent.id)],
    )

    assert response.status_code == 400
    assert "mentioned_agent_ids" in response.json()["error"]["details"]
    assert Message.objects.filter(roundtable=room).count() == 0


def test_user_cannot_send_after_end(api_client):
    room = make_room()
    assert control(api_client, room, "end").status_code == 200

    response = send_user_message(api_client, room, "结束后的消息。")

    assert response.status_code == 400
    assert "status" in response.json()["error"]["details"]


@pytest.mark.django_db(transaction=True)
def test_user_message_and_pause_boundary_are_broadcast(api_client):
    room = make_room()
    turn = start_next_turn(api_client, room)

    async def scenario():
        communicator = WebsocketCommunicator(
            application,
            f"/ws/v1/roundtables/{room.id}/?guest_session={room.guest_session_id}&cursor=2",
        )
        connected, _ = await communicator.connect()
        assert connected
        await communicator.receive_json_from()  # room.joined

        response = await sync_to_async(
            lambda: send_user_message(api_client, room, "请先考虑团队规模。")
        )()
        events = [
            await communicator.receive_json_from(timeout=2),
            await communicator.receive_json_from(timeout=2),
        ]
        await communicator.disconnect()
        return response, events

    response, events = asyncio.run(scenario())

    assert response.status_code == 201
    assert [event["event_type"] for event in events] == [
        "message.completed",
        "room.pause_pending",
    ]
    assert events[0]["payload"]["message"]["author"]["type"] == "user"
    assert events[1]["payload"]["turn_id"] == turn["turn_id"]
