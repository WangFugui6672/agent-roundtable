"""WebSocket activity and deletion boundaries for privacy retention."""

from __future__ import annotations

from datetime import timedelta

import pytest
from asgiref.sync import sync_to_async
from channels.testing import WebsocketCommunicator
from django.utils import timezone

from apps.roundtables.models import GuestSession, Roundtable
from apps.roundtables.tests.test_safety_privacy import make_room
from roundtable.asgi import application

pytestmark = pytest.mark.django_db(transaction=True)


async def test_opening_a_room_over_websocket_renews_retention_activity():
    now = timezone.now()
    room = await sync_to_async(make_room)()
    stale = now - timedelta(days=89)
    await sync_to_async(Roundtable.objects.filter(id=room.id).update)(last_activity_at=stale)
    await sync_to_async(GuestSession.objects.filter(id=room.guest_session_id).update)(
        last_seen_at=stale
    )
    communicator = WebsocketCommunicator(
        application,
        f"/ws/v1/roundtables/{room.id}/?guest_session={room.guest_session_id}",
    )

    connected, _ = await communicator.connect()
    assert connected
    joined = await communicator.receive_json_from(timeout=1)
    assert joined["event_type"] == "room.joined"
    room = await sync_to_async(Roundtable.objects.get)(id=room.id)
    session = await sync_to_async(GuestSession.objects.get)(id=room.guest_session_id)
    assert room.last_activity_at > now
    assert session.last_seen_at > now
    await communicator.disconnect()
