"""Safety, reporting, deletion, and retention contracts (Issue #11)."""

from __future__ import annotations

import uuid
from datetime import timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.test import override_settings
from django.utils import timezone

from apps.roundtables.models import (
    GuestSession,
    Message,
    MessageReport,
    RoomEvent,
    RoundSummary,
    Roundtable,
    RoundtableAgent,
    Turn,
    UsageRecord,
)
from apps.roundtables.services import purge_expired_roundtables

pytestmark = pytest.mark.django_db

TOPIC = "该不该把验证周期压缩到两周？"


def make_room(*, session: GuestSession | None = None) -> Roundtable:
    session = session or GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(
        id=uuid.uuid4(),
        guest_session=session,
        topic=TOPIC,
    )
    for position in range(3):
        from apps.roundtables.tests.factories import create_presets

        profile = create_presets()[position]
        RoundtableAgent.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            agent_profile=profile,
            position=position,
        )
    return room


def make_agent_message(room: Roundtable) -> Message:
    agent = room.agents.first()
    return Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=Message.AuthorType.AGENT,
        roundtable_agent=agent,
        round_number=1,
        message_type=Message.Type.PROPOSAL,
        claim="先做一个小实验。",
        body="先做一个小实验，再根据结果调整。",
    )


def test_user_can_report_an_ai_message_idempotently(api_client):
    room = make_room()
    message = make_agent_message(room)
    headers = {"HTTP_X_GUEST_SESSION": str(room.guest_session_id)}
    path = f"/api/v1/roundtables/{room.id}/messages/{message.id}/reports"

    first = api_client.post(path, {"reason": "harassment"}, format="json", **headers)
    repeated = api_client.post(path, {"reason": "harassment"}, format="json", **headers)

    assert first.status_code == 201
    assert repeated.status_code == 200
    assert first.json()["id"] == repeated.json()["id"]
    assert first.json()["message_id"] == str(message.id)
    assert first.json()["reason"] == "harassment"
    assert first.json()["state"] == "submitted"


def test_report_is_hidden_from_another_guest_session(api_client):
    room = make_room()
    message = make_agent_message(room)
    other = GuestSession.objects.create(id=uuid.uuid4())

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages/{message.id}/reports",
        {"reason": "hate"},
        format="json",
        HTTP_X_GUEST_SESSION=str(other.id),
    )

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "roundtable_not_found"


def test_rejects_reporting_a_user_message(api_client):
    room = make_room()
    message = Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=Message.AuthorType.USER,
        round_number=1,
        message_type=Message.Type.USER_MESSAGE,
        body="这是我自己的消息。",
    )

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/messages/{message.id}/reports",
        {"reason": "other", "details": "不该允许"},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"


def test_delete_roundtable_cascades_and_is_idempotent(api_client):
    room = make_room()
    agent = room.agents.first()
    turn = Turn.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        roundtable_agent=agent,
        round_number=1,
        status=Turn.Status.COMPLETED,
    )
    message = Message.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        author_type=Message.AuthorType.AGENT,
        roundtable_agent=agent,
        turn=turn,
        round_number=1,
        message_type=Message.Type.PROPOSAL,
        claim="先做一个小实验。",
        body="先做一个小实验，再根据结果调整。",
    )
    UsageRecord.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        turn=turn,
        roundtable_agent=agent,
        input_tokens=10,
        output_tokens=20,
    )
    RoundSummary.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        consensus=[{"text": "先实验", "reference_message_ids": [str(message.id)]}],
    )
    RoomEvent.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        sequence=1,
        event_type="message.completed",
        payload={},
    )
    MessageReport.objects.create(
        id=uuid.uuid4(),
        roundtable=room,
        message=message,
        guest_session=room.guest_session,
        reason=MessageReport.Reason.OTHER,
    )
    headers = {"HTTP_X_GUEST_SESSION": str(room.guest_session_id)}
    path = f"/api/v1/roundtables/{room.id}"

    first = api_client.delete(path, **headers)
    repeated = api_client.delete(path, **headers)
    after_delete = api_client.get(path, **headers)

    assert first.status_code == 204
    assert repeated.status_code == 204
    assert after_delete.status_code == 404
    assert not Roundtable.objects.filter(id=room.id).exists()
    assert not Message.objects.filter(roundtable_id=room.id).exists()
    assert not Turn.objects.filter(roundtable_id=room.id).exists()
    assert not UsageRecord.objects.filter(roundtable_id=room.id).exists()
    assert not RoundSummary.objects.filter(roundtable_id=room.id).exists()
    assert not RoomEvent.objects.filter(roundtable_id=room.id).exists()
    assert not MessageReport.objects.filter(roundtable_id=room.id).exists()


def test_another_guest_cannot_delete_the_roundtable(api_client):
    room = make_room()
    other = GuestSession.objects.create(id=uuid.uuid4())

    response = api_client.delete(
        f"/api/v1/roundtables/{room.id}",
        HTTP_X_GUEST_SESSION=str(other.id),
    )

    assert response.status_code == 404
    assert Roundtable.objects.filter(id=room.id).exists()


@override_settings(ROUNDTABLE_RETENTION_DAYS=90)
def test_retention_uses_last_activity_and_purges_only_expired_data():
    now = timezone.now()
    expired = make_room()
    boundary = make_room()
    recent = make_room()
    expired_message = make_agent_message(expired)
    Roundtable.objects.filter(id__in=[expired.id, boundary.id]).update(
        last_activity_at=now - timedelta(days=91)
    )
    Roundtable.objects.filter(id=boundary.id).update(last_activity_at=now - timedelta(days=90))
    Roundtable.objects.filter(id=recent.id).update(last_activity_at=now - timedelta(days=89))
    stale_session = expired.guest_session
    GuestSession.objects.filter(id=stale_session.id).update(last_seen_at=now - timedelta(days=91))

    deleted = purge_expired_roundtables(now=now)

    assert deleted == 2
    assert not Roundtable.objects.filter(id__in=[expired.id, boundary.id]).exists()
    assert not Message.objects.filter(id=expired_message.id).exists()
    assert Roundtable.objects.filter(id=recent.id).exists()
    assert not GuestSession.objects.filter(id=stale_session.id).exists()


@override_settings(ROUNDTABLE_RETENTION_DAYS=90)
def test_user_activity_renews_retention_without_touching_other_rooms(api_client):
    now = timezone.now()
    room = make_room()
    other = make_room()
    old = now - timedelta(days=89)
    Roundtable.objects.filter(id__in=[room.id, other.id]).update(last_activity_at=old)

    response = api_client.post(
        f"/api/v1/roundtables/{room.id}/user-messages",
        {"body": "补充一个新约束。"},
        format="json",
        HTTP_X_GUEST_SESSION=str(room.guest_session_id),
    )

    assert response.status_code == 201
    room.refresh_from_db()
    other.refresh_from_db()
    assert room.last_activity_at > now
    assert other.last_activity_at == old
    purge_expired_roundtables(now=now + timedelta(days=1))
    assert Roundtable.objects.filter(id=room.id).exists()


@override_settings(ROUNDTABLE_RETENTION_DAYS=90)
def test_retention_management_command_reports_without_deleting_in_dry_run():
    room = make_room()
    Roundtable.objects.filter(id=room.id).update(
        last_activity_at=timezone.now() - timedelta(days=91)
    )
    output = StringIO()

    call_command("purge_roundtables", "--dry-run", stdout=output)

    assert "expired_roundtables=1 dry_run=true" in output.getvalue()
    assert Roundtable.objects.filter(id=room.id).exists()
