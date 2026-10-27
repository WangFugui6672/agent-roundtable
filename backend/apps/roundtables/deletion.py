"""Cascade deletion with protected relationships removed in dependency order."""

from __future__ import annotations

from apps.roundtables.models import (
    Message,
    MessageReport,
    RoomEvent,
    RoundSummary,
    Roundtable,
    RoundtableAgent,
    Turn,
    UsageRecord,
)


def delete_room_data(room: Roundtable) -> None:
    """Delete all room-owned rows without tripping PROTECT relationships."""
    MessageReport.objects.filter(roundtable=room).delete()
    UsageRecord.objects.filter(roundtable=room).delete()
    RoundSummary.objects.filter(roundtable=room).delete()

    # Reply versions and their turns protect each other through the original
    # message. Peel the newest message and its regeneration turn together.
    while True:
        unused_turn_ids = list(
            Turn.objects.filter(
                roundtable=room,
                replaces_message__isnull=False,
                messages__isnull=True,
            ).values_list("id", flat=True)
        )
        if unused_turn_ids:
            Turn.objects.filter(id__in=unused_turn_ids).delete()

        leaf_message_ids = list(
            Message.objects.filter(
                roundtable=room,
                supersedes__isnull=False,
                superseded_by__isnull=True,
            ).values_list("id", flat=True)
        )
        if leaf_message_ids:
            Message.objects.filter(id__in=leaf_message_ids).delete()

        if not leaf_message_ids and not unused_turn_ids:
            break

    Message.objects.filter(roundtable=room).delete()
    Turn.objects.filter(roundtable=room).delete()
    RoomEvent.objects.filter(roundtable=room).delete()
    RoundtableAgent.objects.filter(roundtable=room).delete()
    room.delete()
