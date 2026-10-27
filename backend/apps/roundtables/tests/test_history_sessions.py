"""History and anonymous-session lifecycle contracts (PRD 7.1/7.2)."""

from __future__ import annotations

import uuid

import pytest

from apps.roundtables.models import GuestSession, Roundtable

pytestmark = pytest.mark.django_db


def make_room(session: GuestSession, topic: str, status: str) -> Roundtable:
    return Roundtable.objects.create(
        id=uuid.uuid4(),
        guest_session=session,
        topic=topic,
        status=status,
    )


def test_history_lists_only_the_current_sessions_roundtables(api_client):
    session = GuestSession.objects.create(id=uuid.uuid4())
    other = GuestSession.objects.create(id=uuid.uuid4())
    completed = make_room(session, "已完成的议题", Roundtable.Status.COMPLETED)
    running = make_room(session, "进行中的议题", Roundtable.Status.RUNNING)
    make_room(other, "其他会话的议题", Roundtable.Status.RUNNING)

    response = api_client.get(
        "/api/v1/roundtables",
        HTTP_X_GUEST_SESSION=str(session.id),
    )

    assert response.status_code == 200
    body = response.json()
    assert [item["id"] for item in body] == [str(running.id), str(completed.id)]
    assert [item["status"] for item in body] == ["running", "completed"]


def test_rotating_session_invalidates_old_token_and_keeps_ownership(api_client):
    old = GuestSession.objects.create(id=uuid.uuid4())
    room = make_room(old, "轮换后仍应保留", Roundtable.Status.RUNNING)

    rotated = api_client.post(
        "/api/v1/guest-sessions/rotate",
        format="json",
        HTTP_X_GUEST_SESSION=str(old.id),
    )

    assert rotated.status_code == 200
    new_id = uuid.UUID(rotated.json()["id"])
    assert new_id != old.id
    assert not GuestSession.objects.filter(id=old.id).exists()
    room.refresh_from_db()
    assert room.guest_session_id == new_id

    old_access = api_client.get(
        f"/api/v1/roundtables/{room.id}",
        HTTP_X_GUEST_SESSION=str(old.id),
    )
    new_history = api_client.get(
        "/api/v1/roundtables",
        HTTP_X_GUEST_SESSION=str(new_id),
    )
    assert old_access.status_code == 401
    assert new_history.status_code == 200
    assert [item["id"] for item in new_history.json()] == [str(room.id)]


def test_deleting_session_cascades_owned_data_and_invalidates_token(api_client):
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = make_room(session, "会被删除的议题", Roundtable.Status.RUNNING)

    deleted = api_client.delete(
        "/api/v1/guest-sessions/current",
        HTTP_X_GUEST_SESSION=str(session.id),
    )
    repeated = api_client.get(
        "/api/v1/roundtables",
        HTTP_X_GUEST_SESSION=str(session.id),
    )

    assert deleted.status_code == 204
    assert not GuestSession.objects.filter(id=session.id).exists()
    assert not Roundtable.objects.filter(id=room.id).exists()
    assert repeated.status_code == 401
