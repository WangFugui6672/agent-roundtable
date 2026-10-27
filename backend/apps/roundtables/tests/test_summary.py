"""Summary stage, persistence and read-only completion contract (Issue #9)."""

from __future__ import annotations

import uuid

import pytest

from apps.roundtables.models import GuestSession, Roundtable, RoundtableAgent
from apps.roundtables.services import _run_mock_round, build_join_envelope
from apps.roundtables.tests.factories import create_presets

pytestmark = pytest.mark.django_db

TOPIC = "该不该把验证周期压缩到两周？"


def make_room() -> Roundtable:
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(id=uuid.uuid4(), guest_session=session, topic=TOPIC)
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
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 200
    return response.json()


def submit_message(api_client, room: Roundtable, turn: dict, **overrides) -> dict:
    payload = {
        "turn_id": turn["turn_id"],
        "roundtable_agent_id": turn["roundtable_agent_id"],
        "message_type": "proposal",
        "claim": "先完成一个可验证的小实验。",
        "body": "先完成一个两周内的可验证实验，再决定是否扩大投入。",
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


def complete_two_rounds(api_client, room: Roundtable) -> list[dict]:
    messages: list[dict] = []
    for _ in range(3):
        messages.append(submit_message(api_client, room, next_turn(api_client, room)["turn"]))

    next_turn(api_client, room)
    for index in range(3):
        reference = messages[(index + 1) % 3]
        messages.append(
            submit_message(
                api_client,
                room,
                next_turn(api_client, room)["turn"],
                message_type="support",
                stance="support",
                references=[reference["id"]],
            )
        )
    return messages


def test_second_round_end_enters_summarizing_and_is_recoverable(api_client):
    room = make_room()
    complete_two_rounds(api_client, room)

    completed = next_turn(api_client, room)

    assert completed["turn"] is None
    assert [event["event_type"] for event in completed["events"]] == [
        "round.completed",
        "summary.started",
    ]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.SUMMARIZING
    assert room.events.filter(event_type="summary.started", payload__round=2).count() == 1

    reopened = api_client.get(
        f"/api/v1/roundtables/{room.id}",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert reopened.status_code == 200
    assert reopened.json()["status"] == "summarizing"


def test_valid_summary_is_versioned_persisted_and_completes_the_room(api_client):
    room = make_room()
    messages = complete_two_rounds(api_client, room)
    next_turn(api_client, room)
    reference_id = messages[0]["id"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": False,
            "consensus": [
                {"text": "先完成可验证的小实验。", "reference_message_ids": [reference_id]}
            ],
            "dissent": [],
            "recommendations": [
                {
                    "text": "在扩大投入前写清停止条件。",
                    "reference_message_ids": [reference_id],
                }
            ],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201, response.content
    body = response.json()
    assert body["roundtable"]["status"] == "completed"
    assert body["summary"]["version"] == 1
    assert body["summary"]["degraded"] is False
    assert body["summary"]["consensus"][0]["reference_message_ids"] == [reference_id]
    assert [event["event_type"] for event in body["events"]] == ["summary.completed"]
    assert body["events"][0]["payload"]["summary"]["id"] == body["summary"]["id"]

    fetched = api_client.get(
        f"/api/v1/roundtables/{room.id}/summary",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert fetched.status_code == 200
    assert fetched.json()["summary"] == body["summary"]
    joined = build_join_envelope(room)["payload"]
    assert joined["summary"]["id"] == body["summary"]["id"]


def test_summary_cannot_be_submitted_before_round_two_completes(api_client):
    room = make_room()
    turn = next_turn(api_client, room)["turn"]
    message = submit_message(api_client, room, turn)

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": True,
            "consensus": [
                {
                    "text": "过早提交的结论。",
                    "reference_message_ids": [message["id"]],
                }
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "status" in response.json()["error"]["details"]


def test_summary_rejects_api_key_fields_and_unfinished_follow_up(api_client):
    room = make_room()
    turn = next_turn(api_client, room)["turn"]
    message = submit_message(api_client, room, turn)

    follow_up = api_client.post(
        f"/api/v1/roundtables/{room.id}/follow-ups",
        {"topic": "这时候不能继续追问。"},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert follow_up.status_code == 400
    assert "status" in follow_up.json()["error"]["details"]

    rejected = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": True,
            "api_key": "sk-test-secret",
            "consensus": [
                {
                    "text": "不允许上传秘密。",
                    "reference_message_ids": [message["id"]],
                }
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert rejected.status_code == 400
    assert "provider" in rejected.json()["error"]["details"]


def test_user_can_finish_an_early_ended_round_with_a_degraded_summary(api_client):
    room = make_room()
    next_turn(api_client, room)
    ended = api_client.post(
        f"/api/v1/roundtables/{room.id}/end",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert ended.status_code == 200
    assert ended.json()["roundtable"]["status"] == "summarizing"

    summary = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": True,
            "consensus": [],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert summary.status_code == 201
    assert summary.json()["summary"]["degraded"] is True
    assert summary.json()["roundtable"]["status"] == "completed"


def test_summary_regeneration_is_versioned_and_exact_retry_is_idempotent(api_client):
    room = make_room()
    messages = complete_two_rounds(api_client, room)
    next_turn(api_client, room)
    payload = {
        "expected_version": 0,
        "degraded": False,
        "consensus": [
            {
                "text": "先完成可验证的小实验。",
                "reference_message_ids": [messages[0]["id"]],
            }
        ],
        "dissent": [],
        "recommendations": [],
        "unresolved": [],
    }
    first = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        payload,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert first.status_code == 201

    retry = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        payload,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert retry.status_code == 200
    assert retry.json()["summary"]["version"] == 1
    assert retry.json()["events"] == []

    regenerated = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {**payload, "expected_version": 1},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert regenerated.status_code == 201
    assert regenerated.json()["summary"]["version"] == 2
    assert len(regenerated.json()["events"]) == 1

    stale = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            **payload,
            "expected_version": 1,
            "consensus": [
                {
                    "text": "这是一条与已保存版本不同的结论。",
                    "reference_message_ids": [messages[0]["id"]],
                }
            ],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "summary_version_conflict"


def test_summary_rejects_cross_room_and_unknown_references(api_client):
    room = make_room()
    complete_two_rounds(api_client, room)
    next_turn(api_client, room)
    other_room = make_room()
    other_message = submit_message(
        api_client,
        other_room,
        next_turn(api_client, other_room)["turn"],
    )

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": False,
            "consensus": [
                {
                    "text": "不能引用其他圆桌。",
                    "reference_message_ids": [other_message["id"], str(uuid.uuid4())],
                }
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "reference_message_ids" in response.json()["error"]["details"]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.SUMMARIZING


def test_completed_room_rejects_all_discussion_writes_and_controls(api_client):
    room = make_room()
    messages = complete_two_rounds(api_client, room)
    next_turn(api_client, room)
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": False,
            "consensus": [
                {
                    "text": "先完成可验证的小实验。",
                    "reference_message_ids": [messages[0]["id"]],
                }
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 201

    for suffix in ("turns/next", "pause", "resume", "user-messages"):
        rejected = api_client.post(
            f"/api/v1/roundtables/{room.id}/{suffix}",
            {"body": "完成后不能继续写入。"} if suffix == "user-messages" else {},
            format="json",
            HTTP_X_GUEST_SESSION=str(room.guest_session_id),
        )
        assert rejected.status_code == 400, (suffix, rejected.content)


def test_follow_up_creates_a_new_roundtable_with_explicit_parent_and_summary(api_client):
    room = make_room()
    messages = complete_two_rounds(api_client, room)
    next_turn(api_client, room)
    created_summary = api_client.post(
        f"/api/v1/roundtables/{room.id}/summary",
        {
            "expected_version": 0,
            "degraded": False,
            "consensus": [
                {
                    "text": "先完成可验证的小实验。",
                    "reference_message_ids": [messages[0]["id"]],
                }
            ],
            "dissent": [],
            "recommendations": [],
            "unresolved": [],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    ).json()

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/follow-ups",
        {"topic": "如果团队只有两个人，还应该马上扩大验证范围吗？"},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201, response.content
    follow_up = response.json()
    assert follow_up["id"] != str(room.id)
    assert follow_up["status"] == "ready"
    assert follow_up["parent_roundtable_id"] == str(room.id)
    assert follow_up["source_summary_id"] == created_summary["summary"]["id"]
    assert follow_up["follow_up_context"]["parent_topic"] == room.topic
    assert follow_up["follow_up_context"]["summary"]["version"] == 1
    assert len(follow_up["participants"]) == 3


def test_second_mock_round_enters_summarizing():
    room = make_room()

    _run_mock_round(str(room.id), str(room.guest_session_id))
    second = _run_mock_round(str(room.id), str(room.guest_session_id))

    assert second[-1]["event_type"] == "summary.started"
    room.refresh_from_db()
    assert room.status == Roundtable.Status.SUMMARIZING
