"""Structured message submission tests (Issue #4, docs/protocol.md 2.7)."""

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
)
from apps.roundtables.tests.factories import create_presets
from roundtable.asgi import application

TOPIC = "该不该把验证周期压缩到两周？"
BODY = "我建议把议题拆成一个两周内可验证的最小实验：写清假设、指标和停止条件。"

pytestmark = pytest.mark.django_db


def make_room() -> Roundtable:
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(id=uuid.uuid4(), guest_session=session, topic=TOPIC)
    for position, profile in enumerate(create_presets()):
        RoundtableAgent.objects.create(
            id=uuid.uuid4(), roundtable=room, agent_profile=profile, position=position
        )
    return room


def payload(room: Roundtable, **overrides) -> dict:
    agent = room.agents.order_by("position").first()
    body = {
        "roundtable_agent_id": str(agent.id),
        "message_type": "proposal",
        "claim": "先用一个两周的验证性实验确认假设。",
        "body": BODY,
        "confidence": 0.7,
    }
    body.update(overrides)
    return body


def post(api_client, room: Roundtable, **overrides):
    headers = {"HTTP_X_GUEST_SESSION": str(room.guest_session_id)}
    return api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        payload(room, **overrides),
        format="json",
        **headers,
    )


def test_persists_message_and_message_completed_event(api_client):
    room = make_room()
    agent = room.agents.order_by("position").first()

    response = post(api_client, room)

    assert response.status_code == 201
    envelope = response.json()
    assert envelope["event_type"] == "message.completed"
    assert envelope["room_id"] == str(room.id)
    assert envelope["sequence"] == 1

    message = envelope["payload"]["message"]
    assert message["author"]["roundtable_agent_id"] == str(agent.id)
    assert message["author"]["agent_key"] == "advocate"
    assert message["author"]["name"] == "方案派"
    assert message["message_type"] == "proposal"
    assert message["claim"] == "先用一个两周的验证性实验确认假设。"
    assert message["body"] == BODY
    assert message["stance"] is None
    assert message["references"] == []
    assert message["confidence"] == 0.7

    stored = Message.objects.get(id=message["id"])
    assert stored.roundtable == room
    assert stored.roundtable_agent == agent
    assert RoomEvent.objects.filter(
        roundtable=room, sequence=1, event_type="message.completed"
    ).exists()

    agent.refresh_from_db()
    assert agent.state == RoundtableAgent.State.COMPLETED

    room.refresh_from_db()
    assert room.event_sequence == 1
    assert room.status == Roundtable.Status.RUNNING


def test_sequence_increments_per_message(api_client):
    room = make_room()

    first = post(api_client, room)
    second = post(api_client, room, message_type="challenge", claim="我不同意。")

    assert first.json()["sequence"] == 1
    assert second.json()["sequence"] == 2
    assert RoomEvent.objects.filter(roundtable=room).count() == 2


def test_accepts_reference_to_a_message_in_the_same_room(api_client):
    room = make_room()
    first = post(api_client, room).json()["payload"]["message"]

    response = post(
        api_client,
        room,
        message_type="challenge",
        claim="引用前一条主张。",
        references=[first["id"]],
        stance="challenge",
    )

    assert response.status_code == 201
    assert response.json()["payload"]["message"]["references"] == [first["id"]]
    assert Message.objects.get(id=first["id"]).referenced_by.count() == 1


def test_rejects_agent_from_another_roundtable(api_client):
    room = make_room()
    other_room = make_room()
    foreign_agent = other_room.agents.order_by("position").first()

    response = post(api_client, room, roundtable_agent_id=str(foreign_agent.id))

    assert response.status_code == 400
    assert "roundtable_agent_id" in response.json()["error"]["details"]
    assert Message.objects.count() == 0


def test_rejects_unknown_message_type(api_client):
    room = make_room()

    response = post(api_client, room, message_type="rant")

    assert response.status_code == 400
    assert "message_type" in response.json()["error"]["details"]


def test_rejects_body_over_agent_limit(api_client):
    room = make_room()
    agent = room.agents.order_by("position").first()
    limit = agent.agent_profile.max_reply_chars

    response = post(api_client, room, body="字" * (limit + 1))

    assert response.status_code == 400
    details = response.json()["error"]["details"]
    assert str(limit) in str(details)
    assert Message.objects.count() == 0


def test_rejects_empty_body_unless_pass(api_client):
    room = make_room()

    empty = post(api_client, room, body="   ")
    silent = post(api_client, room, message_type="pass", body="", claim="这一轮选择沉默。")

    assert empty.status_code == 400
    assert "body" in empty.json()["error"]["details"]
    assert silent.status_code == 201


def test_rejects_claim_over_limit(api_client):
    room = make_room()

    response = post(api_client, room, claim="长" * 81)

    assert response.status_code == 400
    assert "claim" in response.json()["error"]["details"]


def test_rejects_reference_to_unknown_message(api_client):
    room = make_room()

    response = post(api_client, room, references=[str(uuid.uuid4())])

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


def test_rejects_reference_from_another_roundtable(api_client):
    room = make_room()
    other_room = make_room()
    foreign = post(api_client, other_room).json()["payload"]["message"]

    response = post(api_client, room, references=[foreign["id"]])

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


def test_rejects_api_key_in_message_payload(api_client):
    room = make_room()

    response = post(api_client, room, api_key="sk-should-never-arrive")

    assert response.status_code == 400
    assert "API Key" in response.json()["error"]["message"]
    assert "sk-should-never-arrive" not in response.content.decode()
    assert Message.objects.count() == 0


def test_requires_guest_session_ownership(api_client):
    room = make_room()
    stranger = GuestSession.objects.create(id=uuid.uuid4())

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        payload(room),
        format="json",
        HTTP_X_GUEST_SESSION=str(stranger.id),
    )

    assert response.status_code == 404
    assert Message.objects.count() == 0


@pytest.mark.django_db(transaction=True)
def test_join_payload_includes_persisted_messages():
    room = make_room()
    post_via_orm(room, "第一条主张。")
    post_via_orm(room, "第二条主张。")

    import asyncio

    async def scenario():
        communicator = WebsocketCommunicator(
            application,
            f"/ws/v1/roundtables/{room.id}/?guest_session={room.guest_session_id}",
        )
        connected, _ = await communicator.connect()
        assert connected
        joined = await communicator.receive_json_from()
        await communicator.disconnect()
        return joined

    joined = asyncio.run(scenario())

    assert joined["event_type"] == "room.joined"
    messages = joined["payload"]["messages"]
    assert [message["claim"] for message in messages] == ["第一条主张。", "第二条主张。"]
    assert joined["payload"]["roundtable"]["last_sequence"] == 2


@pytest.mark.django_db(transaction=True)
def test_message_is_broadcast_to_connected_socket(api_client):
    room = make_room()

    import asyncio

    async def scenario():
        communicator = WebsocketCommunicator(
            application,
            f"/ws/v1/roundtables/{room.id}/?guest_session={room.guest_session_id}",
        )
        connected, _ = await communicator.connect()
        assert connected
        await communicator.receive_json_from()  # room.joined

        response = await sync_to_async(
            lambda: api_client.post(
                f"/api/v1/roundtables/{room.id}/messages",
                payload(room),
                format="json",
                HTTP_X_GUEST_SESSION=str(room.guest_session_id),
            )
        )()
        received = await communicator.receive_json_from(timeout=5)
        await communicator.disconnect()
        return response, received

    response, received = asyncio.run(scenario())

    assert response.status_code == 201
    assert received["event_type"] == "message.completed"
    assert received["sequence"] == 1
    assert received["payload"]["message"]["claim"] == "先用一个两周的验证性实验确认假设。"


def post_via_orm(room: Roundtable, claim: str) -> None:
    """Create a message through the service layer, skipping HTTP."""
    from apps.roundtables.services import create_message

    agent = room.agents.order_by("position").first()
    create_message(
        str(room.id),
        str(room.guest_session_id),
        {
            "roundtable_agent_id": agent.id,
            "message_type": Message.Type.PROPOSAL,
            "claim": claim,
            "body": BODY,
            "confidence": 0.6,
        },
    )
