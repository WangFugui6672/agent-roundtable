"""Second-round review contract (Issue #7, docs/protocol.md)."""

from __future__ import annotations

import uuid
from datetime import timedelta

import pytest
from rest_framework.exceptions import ValidationError

from apps.roundtables.models import GuestSession, Message, Roundtable, RoundtableAgent, Turn
from apps.roundtables.services import build_join_envelope, create_message
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


def request_next_turn(api_client, room: Roundtable):
    return api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/next",
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )


def submit_proposal(api_client, room: Roundtable, turn: dict) -> dict:
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先把验证拆成两周实验。",
            "body": "先把验证拆成两周实验，并提前写清停止条件。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 201
    return response.json()["payload"]["message"]


def pass_turn(api_client, room: Roundtable, turn: dict) -> None:
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/pass",
        {
            "turn_id": turn["turn_id"],
            "roundtable_agent_id": turn["roundtable_agent_id"],
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert response.status_code == 201


def test_first_round_end_immediately_starts_round_two(api_client):
    room = make_room()

    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)

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
    assert body["events"][0]["payload"] == {"round": 1}
    assert body["events"][1]["payload"]["round"] == 2
    room.refresh_from_db()
    assert room.current_round == 2
    assert room.status == Roundtable.Status.RUNNING


def test_round_two_rejects_an_agent_message_without_a_reference(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "supplement",
            "claim": "补充一个被验证过的条件。",
            "body": "这个条件需要建立在已有观点上。",
            "stance": "supplement",
            "references": [],
            "confidence": 0.7,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


def test_round_two_accepts_a_challenge_to_another_participants_earlier_view(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "这个方案忽略了验证成本。",
            "body": "我质疑这一点：两周验证本身也会占用最稀缺的团队注意力。",
            "stance": "challenge",
            "references": [skeptic_message["id"]],
            "challenge_target_agent_id": skeptic_message["author"]["roundtable_agent_id"],
            "confidence": 0.76,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    message = response.json()["payload"]["message"]
    assert message["references"] == [skeptic_message["id"]]
    assert message["challenge_target_agent_id"] == skeptic_message["author"]["roundtable_agent_id"]


def test_service_rejects_round_two_message_without_reference(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    with pytest.raises(ValidationError):
        create_message(
            str(room.id),
            str(room.guest_session_id),
            {
                "turn_id": uuid.UUID(round_two["turn_id"]),
                "roundtable_agent_id": uuid.UUID(round_two["roundtable_agent_id"]),
                "message_type": Message.Type.SUPPLEMENT,
                "claim": "绕过接口也必须校验。",
                "body": "没有引用不能被持久化。",
                "stance": Message.Stance.SUPPLEMENT,
                "references": [],
                "confidence": 0.7,
            },
        )

    assert Message.objects.filter(roundtable=room, round_number=2).count() == 0


def test_round_two_rejects_a_self_reference(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    own_message = submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "support",
            "claim": "我支持自己的观点。",
            "body": "这不是互评，必须被拒绝。",
            "stance": "support",
            "references": [own_message["id"]],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


@pytest.mark.parametrize("invalid_kind", ["user", "pass", "summary"])
def test_round_two_rejects_non_opinion_references(api_client, invalid_kind):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    skeptic = room.agents.order_by("position")[1]
    invalid_reference = Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=(
            Message.AuthorType.USER if invalid_kind == "user" else Message.AuthorType.AGENT
        ),
        roundtable_agent=None if invalid_kind == "user" else skeptic,
        round_number=1,
        message_type={
            "user": Message.Type.USER_MESSAGE,
            "pass": Message.Type.PASS,
            "summary": Message.Type.SUMMARY,
        }[invalid_kind],
        claim="" if invalid_kind == "user" else "不是有效观点",
        body="不能作为第二轮引用依据。",
        stance="",
        confidence=None if invalid_kind == "user" else 0.6,
    )
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "support",
            "claim": "这是一个无效引用。",
            "body": "用户消息、沉默和总结都不是可互评的有效观点。",
            "stance": "support",
            "references": [str(invalid_reference.id)],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


def test_round_two_rejects_a_later_message_reference(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]
    skeptic = room.agents.order_by("position")[1]
    later_message = Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=Message.AuthorType.AGENT,
        roundtable_agent=skeptic,
        round_number=2,
        message_type=Message.Type.SUPPLEMENT,
        claim="这是之后才产生的观点。",
        body="签发当前 turn 时它还不存在，不能被引用。",
        stance=Message.Stance.SUPPLEMENT,
        confidence=0.6,
    )

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "support",
            "claim": "不能穿越到未来引用。",
            "body": "引用必须来自当前 turn 签发前已经持久化的观点。",
            "stance": "support",
            "references": [str(later_message.id)],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "references" in response.json()["error"]["details"]


def test_round_two_rejects_message_type_and_stance_mismatch(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "support",
            "claim": "类型和立场必须一致。",
            "body": "接口不能把支持类型和质疑立场混在一起。",
            "stance": "challenge",
            "references": [skeptic_message["id"]],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    details = response.json()["error"]["details"]
    assert "stance" in details or "message_type" in details


def test_round_two_challenge_requires_a_challenge_target(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "质疑必须指向一个明确对象。",
            "body": "只有质疑立场但没有挑战对象，客户端无法恢复完整关系。",
            "stance": "challenge",
            "references": [skeptic_message["id"]],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "challenge_target_agent_id" in response.json()["error"]["details"]


@pytest.mark.parametrize(
    "target_kind",
    ["self", "unreferenced", "foreign", "non_challenge"],
)
def test_round_two_rejects_inconsistent_challenge_targets(api_client, target_kind):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)
    round_two = request_next_turn(api_client, room).json()["turn"]
    foreign_agent = make_room().agents.order_by("position").first()
    target_id = {
        "self": round_two["roundtable_agent_id"],
        "unreferenced": str(room.agents.order_by("position")[2].id),
        "foreign": str(foreign_agent.id),
        "non_challenge": skeptic_message["author"]["roundtable_agent_id"],
    }[target_kind]
    stance = "support" if target_kind == "non_challenge" else "challenge"

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two["turn_id"],
            "roundtable_agent_id": round_two["roundtable_agent_id"],
            "message_type": stance,
            "claim": "挑战关系必须一致。",
            "body": "挑战对象、立场和引用作者必须形成明确关系。",
            "stance": stance,
            "references": [skeptic_message["id"]],
            "challenge_target_agent_id": target_id,
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "challenge_target_agent_id" in response.json()["error"]["details"]


def test_service_rejects_a_blank_claim(api_client):
    room = make_room()
    turn = request_next_turn(api_client, room).json()["turn"]

    with pytest.raises(ValidationError):
        create_message(
            str(room.id),
            str(room.guest_session_id),
            {
                "turn_id": uuid.UUID(turn["turn_id"]),
                "roundtable_agent_id": uuid.UUID(turn["roundtable_agent_id"]),
                "message_type": Message.Type.PROPOSAL,
                "claim": "   ",
                "body": "正文不应在没有主张时落库。",
                "confidence": 0.6,
            },
        )

    assert Message.objects.filter(roundtable=room).count() == 0


def test_round_two_completes_once_after_each_participant_reviews(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    first_message = submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)

    round_two_first = request_next_turn(api_client, room).json()["turn"]
    first_review = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two_first["turn_id"],
            "roundtable_agent_id": round_two_first["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "验证成本仍然被低估。",
            "body": "我质疑这个方案，因为它没有计算团队注意力的机会成本。",
            "stance": "challenge",
            "references": [skeptic_message["id"]],
            "challenge_target_agent_id": skeptic_message["author"]["roundtable_agent_id"],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert first_review.status_code == 201
    first_review_message = first_review.json()["payload"]["message"]

    round_two_second = request_next_turn(api_client, room).json()["turn"]
    second_review = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two_second["turn_id"],
            "roundtable_agent_id": round_two_second["roundtable_agent_id"],
            "message_type": "support",
            "claim": "成本判断需要被纳入方案。",
            "body": "我支持对成本的追问，并补充它应成为实验启动前的检查项。",
            "stance": "support",
            "references": [first_review_message["id"]],
            "confidence": 0.72,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert second_review.status_code == 201

    round_two_third = request_next_turn(api_client, room).json()["turn"]
    third_review = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two_third["turn_id"],
            "roundtable_agent_id": round_two_third["roundtable_agent_id"],
            "message_type": "question",
            "claim": "谁负责判断成本是否可接受？",
            "body": "我想追问提出的方案，最终由谁承担这个判断责任？",
            "stance": "question",
            "references": [first_message["id"]],
            "confidence": 0.66,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert third_review.status_code == 201

    completed = request_next_turn(api_client, room)
    repeated = request_next_turn(api_client, room)

    assert completed.status_code == 200
    assert completed.json()["turn"] is None
    assert [event["event_type"] for event in completed.json()["events"]] == [
        "round.completed",
        "summary.started",
    ]
    assert completed.json()["events"][0]["payload"] == {"round": 2}
    assert repeated.status_code == 400
    assert "status" in repeated.json()["error"]["details"]
    room.refresh_from_db()
    assert room.current_round == 2
    assert room.status == Roundtable.Status.SUMMARIZING
    assert room.events.filter(event_type="round.completed", payload__round=2).count() == 1
    assert room.events.filter(event_type="summary.started", payload__round=2).count() == 1
    restored = build_join_envelope(room)["payload"]["messages"]
    round_two_messages = [message for message in restored if message["round_number"] == 2]
    assert [message["stance"] for message in round_two_messages] == [
        "challenge",
        "support",
        "question",
    ]
    assert all(message["references"] for message in round_two_messages)
    assert (
        round_two_messages[0]["challenge_target_agent_id"]
        == skeptic_message["author"]["roundtable_agent_id"]
    )


def test_round_two_accepts_same_round_view_when_message_commit_timestamp_is_later(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    submit_proposal(api_client, room, first)
    second = request_next_turn(api_client, room).json()["turn"]
    skeptic_message = submit_proposal(api_client, room, second)
    third = request_next_turn(api_client, room).json()["turn"]
    pass_turn(api_client, room, third)

    round_two_first = request_next_turn(api_client, room).json()["turn"]
    first_review = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two_first["turn_id"],
            "roundtable_agent_id": round_two_first["roundtable_agent_id"],
            "message_type": "challenge",
            "claim": "验证成本仍然被低估。",
            "body": "我质疑这个方案，因为它没有计算团队注意力的机会成本。",
            "stance": "challenge",
            "references": [skeptic_message["id"]],
            "challenge_target_agent_id": skeptic_message["author"]["roundtable_agent_id"],
            "confidence": 0.8,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert first_review.status_code == 201
    first_review_message = first_review.json()["payload"]["message"]

    round_two_second = request_next_turn(api_client, room).json()["turn"]
    next_turn = Turn.objects.get(id=round_two_second["turn_id"])
    previous_turn = Turn.objects.get(id=first_review_message["turn_id"])
    assert previous_turn.created_at < next_turn.created_at

    Message.objects.filter(id=first_review_message["id"]).update(
        created_at=next_turn.created_at + timedelta(seconds=1)
    )
    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": round_two_second["turn_id"],
            "roundtable_agent_id": round_two_second["roundtable_agent_id"],
            "message_type": "support",
            "claim": "接受成本约束。",
            "body": "上一轮的质疑成立，成本需要成为实验启动前的检查项。",
            "stance": "support",
            "references": [first_review_message["id"]],
            "confidence": 0.72,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    assert response.json()["payload"]["message"]["references"] == [first_review_message["id"]]
