"""WebSocket endpoint for one roundtable.

Protocol: docs/protocol.md. The mix of persisted log events and the ephemeral
``room.joined`` snapshot is described there; keep the two in sync.
"""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any
from urllib.parse import parse_qs

from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.roundtables import protocol as p
from apps.roundtables.services import (
    events_after,
    join_snapshot,
    room_access_allowed,
    room_group_name,
    run_mock_round,
)

logger = logging.getLogger(__name__)

CLOSE_UNAUTHORIZED = 4401
CLOSE_BAD_REQUEST = 4400


def _is_uuid(raw: str) -> bool:
    try:
        uuid.UUID(raw)
    except ValueError:
        return False
    return True


class RoundtableConsumer(AsyncJsonWebsocketConsumer):
    async def connect(self) -> None:
        self.roundtable_id: str = self.scope["url_route"]["kwargs"]["roundtable_id"]
        params = parse_qs(self.scope["query_string"].decode())
        self.guest_session_id = (params.get("guest_session") or [""])[0]
        self.replaying = False
        self.buffered_live_events: list[dict[str, Any]] = []
        self.sent_event_ids: set[str] = set()

        try:
            self.cursor = int((params.get("cursor") or ["0"])[0])
        except ValueError:
            await self.close(code=CLOSE_BAD_REQUEST)
            return
        if self.cursor < 0:
            await self.close(code=CLOSE_BAD_REQUEST)
            return

        if (
            not self.guest_session_id
            or not _is_uuid(self.guest_session_id)
            or not _is_uuid(self.roundtable_id)
        ):
            await self.close(code=CLOSE_UNAUTHORIZED)
            return

        if not await room_access_allowed(self.roundtable_id, self.guest_session_id):
            await self.close(code=CLOSE_UNAUTHORIZED)
            return

        # Subscribe before building the snapshot. Events committed between
        # snapshot reads stay queued and are sent after joined/replay.
        self.replaying = True
        await self.channel_layer.group_add(room_group_name(self.roundtable_id), self.channel_name)

        snapshot = await join_snapshot(self.roundtable_id, self.guest_session_id, self.cursor)
        if snapshot is None:
            await self.channel_layer.group_discard(
                room_group_name(self.roundtable_id),
                self.channel_name,
            )
            await self.close(code=CLOSE_UNAUTHORIZED)
            return

        await self.accept()
        await self._send_event(snapshot)

        replay = snapshot["payload"]["replay"]
        if not replay["cursor_expired"]:
            for envelope in await events_after(
                self.roundtable_id,
                self.guest_session_id,
                self.cursor,
            ):
                await self._send_event(envelope)

        await self._flush_buffered_events()
        self.replaying = False

    async def disconnect(self, code: int) -> None:
        if hasattr(self, "roundtable_id"):
            await self.channel_layer.group_discard(
                room_group_name(self.roundtable_id), self.channel_name
            )

    async def room_event(self, event: dict[str, Any]) -> None:
        """Fan-out from the roundtable command service."""
        if self.replaying:
            self.buffered_live_events.append(event["envelope"])
            return
        await self._send_event(event["envelope"])

    async def _flush_buffered_events(self) -> None:
        while self.buffered_live_events:
            buffered = sorted(
                self.buffered_live_events,
                key=lambda envelope: envelope["sequence"],
            )
            self.buffered_live_events.clear()
            for envelope in buffered:
                await self._send_event(envelope)

    async def _send_event(self, envelope: dict[str, Any]) -> None:
        event_id = envelope["event_id"]
        if event_id in self.sent_event_ids:
            return
        self.sent_event_ids.add(event_id)
        await self.send_json(envelope)

    async def receive(self, text_data=None, bytes_data=None, **kwargs) -> None:
        if text_data is None:
            return
        try:
            content: dict[str, Any] = json.loads(text_data)
        except json.JSONDecodeError:
            await self.close(code=CLOSE_BAD_REQUEST)
            return
        await self.receive_json(content, **kwargs)

    async def receive_json(self, content: dict[str, Any], **kwargs) -> None:
        if content.get("event_type") != p.MOCK_RUN:
            # Unknown client commands are ignored on purpose so older servers
            # never break newer clients that probe for capabilities.
            logger.info("Ignoring unsupported client command: %r", content.get("event_type"))
            return

        for envelope in await run_mock_round(self.roundtable_id, self.guest_session_id):
            await self.send_json(envelope)
