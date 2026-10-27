"""Guest-session history and lifecycle operations."""

from __future__ import annotations

import uuid

from django.db import transaction

from apps.roundtables.deletion import delete_room_data
from apps.roundtables.models import GuestSession, MessageReport, Roundtable


def list_roundtables(guest_session: GuestSession) -> list[Roundtable]:
    return list(
        Roundtable.objects.filter(guest_session=guest_session)
        .prefetch_related(
            "agents__agent_profile",
            "parent_roundtable",
            "source_summary",
        )
        .order_by("-created_at", "-id")[:100]
    )


def rotate_guest_session(guest_session: GuestSession) -> GuestSession:
    """Move owned data to a fresh bearer token and invalidate the old row."""
    with transaction.atomic():
        old = GuestSession.objects.select_for_update().get(id=guest_session.id)
        replacement = GuestSession.objects.create(id=uuid.uuid4())
        Roundtable.objects.filter(guest_session=old).update(guest_session=replacement)
        MessageReport.objects.filter(guest_session=old).update(guest_session=replacement)
        old.delete()
        return replacement


def delete_guest_session(guest_session: GuestSession) -> None:
    """Delete the bearer token and all data reachable from its ownership."""
    with transaction.atomic():
        old = GuestSession.objects.select_for_update().get(id=guest_session.id)
        rooms = list(Roundtable.objects.select_for_update().filter(guest_session=old))
        for room in rooms:
            delete_room_data(room)
        MessageReport.objects.filter(guest_session=old).delete()
        old.delete()
