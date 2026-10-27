"""Key-point and response-version contracts (PRD 7.8)."""

from __future__ import annotations

import uuid

import pytest

from apps.roundtables.models import GuestSession, Message, Roundtable, RoundtableAgent
from apps.roundtables.services import build_join_envelope
from apps.roundtables.tests.factories import create_presets

pytestmark = pytest.mark.django_db


def make_room() -> Roundtable:
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(id=uuid.uuid4(), guest_session=session, topic="版本测试")
    for position, profile in enumerate(create_presets()):
        RoundtableAgent.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            agent_profile=profile,
            position=position,
        )
    return room


def next_turn(api_client, room: Roundtable) -> dict:
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 200, response.content
    return response.json()["turn"]


def submit_message(api_client, room: Roundtable, turn: dict, **overrides) -> dict:
    payload = {
        "turn_id": turn["turn_id"],
        "roundtable_agent_id": turn["roundtable_agent_id"],
        "message_type": "proposal",
        "claim": "先做一个小实验。",
        "body": "先做一个小实验，再决定是否扩大投入。",
        **overrides,
    }
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        payload,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 201, response.content
    return response.json()["payload"]["message"]


def test_key_point_is_idempotent_and_does_not_change_message_text(api_client):
    room = make_room()
    message = submit_message(api_client, room, next_turn(api_client, room))
    path = f"/api/v1/roundtables/{room.id}/messages/{message['id']}/key-point"
    headers = {"HTTP_X_GUEST_SESSION": str(room.guest_session_id)}

    marked = api_client.patch(path, {"is_key_point": True}, format="json", **headers)
    repeated = api_client.patch(path, {"is_key_point": True}, format="json", **headers)

    assert marked.status_code == 200
    assert repeated.status_code == 200
    assert marked.json()["is_key_point"] is True
    stored = Message.objects.get(id=message["id"])
    assert stored.is_key_point is True
    assert stored.claim == message["claim"]
    assert stored.body == message["body"]


def test_regeneration_creates_a_new_version_without_rewriting_the_old_one(api_client):
    room = make_room()
    old = submit_message(
        api_client,
        room,
        next_turn(api_client, room),
        claim="旧版本主张。",
        body="旧版本正文，必须原样保留。",
    )
    referencing = submit_message(
        api_client,
        room,
        next_turn(api_client, room),
        claim="引用旧版本。",
        body="后续观点仍然引用旧版本。",
        references=[old["id"]],
    )
    path = f"/api/v1/roundtables/{room.id}/messages/{old['id']}/regenerate"
    headers = {"HTTP_X_GUEST_SESSION": str(room.guest_session_id)}

    first = api_client.post(path, format="json", **headers)
    repeated = api_client.post(path, format="json", **headers)

    assert first.status_code == 201, first.content
    assert repeated.status_code == 200, repeated.content
    assert repeated.json()["turn"] == first.json()["turn"]
    assert [event["event_type"] for event in first.json()["events"]] == ["agent.thinking"]
    replacement = submit_message(
        api_client,
        room,
        first.json()["turn"],
        claim="新版本主张。",
        body="新版本正文。",
    )

    old_record = Message.objects.get(id=old["id"])
    reference_record = Message.objects.get(id=referencing["id"])
    replacement_record = Message.objects.get(id=replacement["id"])
    assert old_record.claim == "旧版本主张。"
    assert old_record.body == "旧版本正文，必须原样保留。"
    assert old_record.superseded_by.id == replacement_record.id
    assert replacement_record.supersedes_id == old_record.id
    assert list(reference_record.references.values_list("id", flat=True)) == [old_record.id]

    replay = api_client.post(path, format="json", **headers)
    assert replay.status_code == 200
    assert replay.json()["turn"] is None
    assert replay.json()["replacement_message_id"] == replacement["id"]

    joined = build_join_envelope(room)
    messages = {item["id"]: item for item in joined["payload"]["messages"]}
    assert messages[old["id"]]["superseded_by_message_id"] == replacement["id"]
    assert messages[replacement["id"]]["supersedes_message_id"] == old["id"]


def test_regeneration_rejects_user_messages(api_client):
    room = make_room()
    user_message = Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=Message.AuthorType.USER,
        message_type=Message.Type.USER_MESSAGE,
        body="用户消息不能重生成。",
    )

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages/{user_message.id}/regenerate",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"
