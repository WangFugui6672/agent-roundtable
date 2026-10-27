"""Failure recovery and discussion budget contracts (Issue #10)."""

from __future__ import annotations

import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Barrier

import pytest
from django.db import close_old_connections
from django.utils import timezone
from rest_framework.test import APIClient

from apps.roundtables.budget import MAX_DISCUSSION_SECONDS
from apps.roundtables.models import (
    GuestSession,
    Message,
    Roundtable,
    RoundtableAgent,
    Turn,
    UsageRecord,
)
from apps.roundtables.services import build_join_envelope
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


def test_agent_failure_is_visible_and_does_not_block_the_next_agent(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "failure_code": "provider_timeout",
            "message": "请求超时，请稍后重试。",
            "retryable": True,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    event = response.json()
    assert event["event_type"] == "agent.failed"
    assert event["payload"] == {
        "turn_id": first["turn_id"],
        "round": 1,
        "agent_id": first["roundtable_agent_id"],
        "agent_name": "方案派",
        "failure_code": "provider_timeout",
        "message": "请求超时，请稍后重试。",
        "retryable": True,
        "partial": None,
    }

    failed_turn = Turn.objects.get(id=first["turn_id"])
    assert failed_turn.status == Turn.Status.FAILED
    assert failed_turn.failure_code == "provider_timeout"
    assert failed_turn.retryable is True
    assert Message.objects.filter(roundtable=room).count() == 0

    next_response = request_next_turn(api_client, room)

    assert next_response.status_code == 200
    assert next_response.json()["turn"]["agent_key"] == "skeptic"


def test_agent_failure_records_client_reported_usage_and_partial(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "failure_code": "provider_rate_limited",
            "message": "Provider 限流，请稍后重试。",
            "retryable": True,
            "partial": "我已经生成了前半段观点",
            "usage": {
                "input_tokens": 120,
                "output_tokens": 35,
                "latency_ms": 6400,
                "retry_count": 1,
            },
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    assert response.json()["payload"]["partial"] == "我已经生成了前半段观点"
    usage = UsageRecord.objects.get(turn_id=first["turn_id"])
    assert usage.roundtable == room
    assert usage.roundtable_agent_id == uuid.UUID(first["roundtable_agent_id"])
    assert usage.input_tokens == 120
    assert usage.output_tokens == 35
    assert usage.latency_ms == 6400
    assert usage.retry_count == 1
    assert usage.failure_code == "provider_rate_limited"
    assert Turn.objects.get(id=first["turn_id"]).failure_partial == "我已经生成了前半段观点"


def test_failed_turn_is_restored_once_and_rejects_a_duplicate_report(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    body = {
        "turn_id": first["turn_id"],
        "roundtable_agent_id": first["roundtable_agent_id"],
        "failure_code": "provider_network",
        "message": "网络请求失败。",
        "retryable": True,
        "partial": "已经生成的观点",
    }
    request_body = {
        **body,
    }

    first_response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        request_body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    duplicate = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        request_body,
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert first_response.status_code == 201
    assert duplicate.status_code == 400
    restored = build_join_envelope(room)["payload"]["failures"]
    assert restored == [
        {
            "turn_id": first["turn_id"],
            "round": 1,
            "agent_id": first["roundtable_agent_id"],
            "agent_name": "方案派",
            "failure_code": "provider_network",
            "message": "网络请求失败。",
            "retryable": True,
            "partial": "已经生成的观点",
        }
    ]
    assert room.events.filter(event_type="agent.failed").count() == 1


def test_failure_report_rejects_the_wrong_agent_and_keeps_turn_pending(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    other_agent = room.agents.order_by("position")[1]

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": str(other_agent.id),
            "failure_code": "provider_timeout",
            "message": "错误的 Agent 回报。",
            "retryable": True,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert "roundtable_agent_id" in response.json()["error"]["details"]
    assert Turn.objects.get(id=first["turn_id"]).status == Turn.Status.PENDING
    assert room.events.filter(event_type="agent.failed").count() == 0


def test_failure_after_a_completed_message_keeps_the_message_and_continues(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先保留这个观点。",
            "body": "后续 Agent 失败不应破坏已经完成的观点。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    second = request_next_turn(api_client, room).json()["turn"]

    failed = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": second["turn_id"],
            "roundtable_agent_id": second["roundtable_agent_id"],
            "failure_code": "provider_network",
            "message": "网络断开。",
            "retryable": True,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    next_response = request_next_turn(api_client, room)

    assert failed.status_code == 201
    assert Message.objects.filter(roundtable=room).count() == 1
    assert next_response.json()["turn"]["agent_key"] == "experience"
    restored_messages = build_join_envelope(room)["payload"]["messages"]
    assert [message["claim"] for message in restored_messages] == ["先保留这个观点。"]


def test_guest_session_can_have_at_most_three_active_roundtables(api_client, agent_profiles):
    session = GuestSession.objects.create(id=uuid.uuid4())
    headers = {"HTTP_X_GUEST_SESSION": str(session.id)}
    payload = {
        "topic": TOPIC,
        "agent_profile_ids": [str(profile.id) for profile in agent_profiles],
    }

    created = [
        api_client.post("/api/v1/roundtables", payload, format="json", **headers) for _ in range(3)
    ]
    fourth = api_client.post("/api/v1/roundtables", payload, format="json", **headers)

    assert [response.status_code for response in created] == [201, 201, 201]
    assert fourth.status_code == 429
    assert fourth.json()["error"]["code"] == "active_roundtable_limit"
    assert "3" in fourth.json()["error"]["message"]

    finished = Roundtable.objects.filter(guest_session=session).first()
    assert finished is not None
    finished.status = Roundtable.Status.COMPLETED
    finished.save(update_fields=["status"])
    after_completion = api_client.post("/api/v1/roundtables", payload, format="json", **headers)
    assert after_completion.status_code == 201


def test_mock_roundtables_are_limited_to_ten_per_utc_day(api_client, agent_profiles):
    session = GuestSession.objects.create(id=uuid.uuid4())
    for _ in range(10):
        Roundtable.objects.create(
            id=uuid.uuid4(),
            guest_session=session,
            topic=TOPIC,
            status=Roundtable.Status.COMPLETED,
            created_at=datetime.now(tz=UTC),
        )
    payload = {
        "topic": TOPIC,
        "agent_profile_ids": [str(profile.id) for profile in agent_profiles],
    }
    headers = {"HTTP_X_GUEST_SESSION": str(session.id)}

    blocked = api_client.post("/api/v1/roundtables", payload, format="json", **headers)
    real_provider = api_client.post(
        "/api/v1/roundtables",
        {
            **payload,
            "provider": {
                "kind": "deepseek",
                "base_url": "https://api.deepseek.com/v1",
                "model": "deepseek-chat",
            },
        },
        format="json",
        **headers,
    )

    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "mock_daily_limit"
    assert "10" in blocked.json()["error"]["message"]
    assert real_provider.status_code == 201


@pytest.mark.django_db(transaction=True)
def test_concurrent_creation_cannot_exceed_the_active_room_limit(agent_profiles):
    session = GuestSession.objects.create(id=uuid.uuid4())
    barrier = Barrier(4)
    payload = {
        "topic": TOPIC,
        "agent_profile_ids": [str(profile.id) for profile in agent_profiles],
    }

    def create_roundtable() -> int:
        close_old_connections()
        try:
            client = APIClient()
            barrier.wait(timeout=5)
            response = client.post(
                "/api/v1/roundtables",
                payload,
                format="json",
                HTTP_X_GUEST_SESSION=str(session.id),
            )
            return response.status_code
        finally:
            close_old_connections()

    with ThreadPoolExecutor(max_workers=4) as executor:
        statuses = list(executor.map(lambda _: create_roundtable(), range(4)))

    assert sorted(statuses) == [201, 201, 201, 429]
    assert Roundtable.objects.filter(guest_session=session).count() == 3


def test_duration_budget_ends_the_room_once_with_a_recoverable_event(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "failure_code": "provider_timeout",
            "message": "第一次调用超时。",
            "retryable": True,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    room.refresh_from_db()
    room.started_at = timezone.now() - timedelta(seconds=MAX_DISCUSSION_SECONDS + 1)
    room.save(update_fields=["started_at"])

    exhausted = request_next_turn(api_client, room)
    repeated = request_next_turn(api_client, room)
    snapshot = api_client.get(
        f"/api/v1/roundtables/{room.id}",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    ).json()

    assert exhausted.status_code == 200
    assert exhausted.json()["turn"] is None
    event = exhausted.json()["events"][0]
    assert event["event_type"] == "budget.exhausted"
    assert event["payload"] == {
        "reason": "duration",
        "message": f"讨论已达到 {MAX_DISCUSSION_SECONDS} 秒时间上限。",
        "round": 1,
    }
    assert repeated.status_code == 400
    assert "status" in repeated.json()["error"]["details"]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.COMPLETED
    assert room.budget_exhausted_reason == "duration"
    assert room.events.filter(event_type="budget.exhausted").count() == 1
    budget = snapshot["budget"]
    assert budget["max_rounds"] == 2
    assert budget["max_agent_messages"] == 6
    assert budget["agent_messages_used"] == 0
    assert budget["max_reported_tokens"] == 2400
    assert budget["reported_tokens"] == 0
    assert budget["max_duration_seconds"] == MAX_DISCUSSION_SECONDS
    assert budget["started_at"].endswith("Z")
    assert budget["elapsed_seconds"] >= MAX_DISCUSSION_SECONDS
    assert budget["exhausted_reason"] == "duration"
    assert budget["token_source"] == "client_reported"


def test_reported_tokens_are_advisory_and_do_not_stop_the_next_agent(
    api_client,
):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]

    message_response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做验证。",
            "body": "先做一个最小验证，再决定是否扩大投入。",
            "usage": {
                "input_tokens": 1500,
                "output_tokens": 1000,
                "latency_ms": 3200,
                "retry_count": 0,
            },
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    next_response = request_next_turn(api_client, room)

    assert message_response.status_code == 201
    assert next_response.status_code == 200
    assert next_response.json()["turn"] is not None
    assert all(
        event["event_type"] != "budget.exhausted" for event in next_response.json()["events"]
    )
    assert next_response.json()["budget"]["reported_tokens"] == 2500
    room.refresh_from_db()
    assert room.status == Roundtable.Status.RUNNING
    assert room.reported_tokens == 2500
    assert Message.objects.filter(roundtable=room).count() == 1
    assert UsageRecord.objects.get(turn_id=first["turn_id"]).failure_code == ""


def test_agent_message_budget_stops_the_next_turn(api_client):
    room = make_room()
    room.max_agent_messages = 1
    room.save(update_fields=["max_agent_messages"])
    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/messages",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "message_type": "proposal",
            "claim": "先做一个验证。",
            "body": "这条消息会耗尽消息数预算。",
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    exhausted = request_next_turn(api_client, room)

    assert exhausted.json()["turn"] is None
    assert exhausted.json()["events"][0]["payload"]["reason"] == "agent_messages"
    assert Message.objects.filter(roundtable=room).count() == 1


def test_expired_turn_is_closed_once_and_the_next_agent_is_scheduled(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    turn = Turn.objects.get(id=first["turn_id"])
    turn.deadline_at = timezone.now() - timedelta(seconds=1)
    turn.save(update_fields=["deadline_at"])

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    body = response.json()
    assert body["turn"]["agent_key"] == "skeptic"
    assert [event["event_type"] for event in body["events"]] == [
        "agent.failed",
        "agent.thinking",
    ]
    failure = body["events"][0]["payload"]
    assert failure["failure_code"] == "turn_timeout"
    assert failure["retryable"] is True
    turn.refresh_from_db()
    assert turn.status == Turn.Status.FAILED
    assert room.events.filter(event_type="agent.failed").count() == 1

    late_report = api_client.post(
        f"/api/v1/roundtables/{room.id}/turns/fail",
        {
            "turn_id": first["turn_id"],
            "roundtable_agent_id": first["roundtable_agent_id"],
            "failure_code": "provider_timeout",
            "message": "迟到的失败回报。",
            "retryable": True,
        },
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    assert late_report.status_code == 400


def test_final_round_completion_wins_over_duration_budget(api_client):
    room = make_room()
    room.current_round = 2
    room.status = Roundtable.Status.RUNNING
    room.started_at = timezone.now() - timedelta(seconds=MAX_DISCUSSION_SECONDS + 1)
    room.save(update_fields=["current_round", "status", "started_at"])
    room.agents.update(state=RoundtableAgent.State.COMPLETED)

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    assert [event["event_type"] for event in response.json()["events"]] == [
        "round.completed",
        "summary.started",
    ]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.SUMMARIZING
    assert room.budget_exhausted_reason == ""
    assert room.events.filter(event_type="budget.exhausted").count() == 0


def test_final_round_expired_turn_returns_both_failure_and_completion(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    turn = Turn.objects.get(id=first["turn_id"])
    turn.round_number = 2
    turn.deadline_at = timezone.now() - timedelta(seconds=1)
    turn.save(update_fields=["round_number", "deadline_at"])
    room.current_round = 2
    room.status = Roundtable.Status.RUNNING
    room.save(update_fields=["current_round", "status"])
    room.agents.exclude(id=first["roundtable_agent_id"]).update(
        state=RoundtableAgent.State.COMPLETED
    )

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    assert response.json()["turn"] is None
    assert [event["event_type"] for event in response.json()["events"]] == [
        "agent.failed",
        "round.completed",
        "summary.started",
    ]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.SUMMARIZING


def test_expired_turn_honors_pause_pending_before_scheduling_another_agent(api_client):
    room = make_room()
    first = request_next_turn(api_client, room).json()["turn"]
    api_client.post(
        f"/api/v1/roundtables/{room.id}/user-messages",
        {"body": "先在这里暂停一下。"},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )
    turn = Turn.objects.get(id=first["turn_id"])
    turn.deadline_at = timezone.now() - timedelta(seconds=1)
    turn.save(update_fields=["deadline_at"])

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    assert response.json()["turn"] is None
    assert [event["event_type"] for event in response.json()["events"]] == [
        "agent.failed",
        "room.paused",
    ]
    room.refresh_from_db()
    assert room.status == Roundtable.Status.PAUSED
    assert room.pause_pending is False


def test_budget_between_rounds_does_not_start_round_two(api_client):
    room = make_room()
    room.current_round = 1
    room.status = Roundtable.Status.RUNNING
    room.started_at = timezone.now() - timedelta(seconds=MAX_DISCUSSION_SECONDS + 1)
    room.save(update_fields=["current_round", "status", "started_at"])
    room.agents.update(state=RoundtableAgent.State.COMPLETED)

    response = request_next_turn(api_client, room)

    assert response.status_code == 200
    assert response.json()["turn"] is None
    assert [event["event_type"] for event in response.json()["events"]] == [
        "round.completed",
        "budget.exhausted",
    ]
    room.refresh_from_db()
    assert room.current_round == 1
    assert room.status == Roundtable.Status.COMPLETED
    assert room.budget_exhausted_reason == "duration"
