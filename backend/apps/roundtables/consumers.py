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
from apps.roundtables.services import events_after, join_snapshot, run_mock_round

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

        snapshot = await join_snapshot(self.roundtable_id, self.guest_session_id)
        if snapshot is None:
            await self.close(code=CLOSE_UNAUTHORIZED)
            return

        await self.accept()
        await self.send_json(snapshot)

        for envelope in await events_after(self.roundtable_id, self.guest_session_id, self.cursor):
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
        # TODO(#5): delete this branch once the turn scheduler drives events.
        if content.get("event_type") != p.MOCK_RUN:
            # Unknown client commands are ignored on purpose so older servers
            # never break newer clients that probe for capabilities.
            logger.info("Ignoring unsupported client command: %r", content.get("event_type"))
            return

        for envelope in await run_mock_round(self.roundtable_id, self.guest_session_id):
            await self.send_json(envelope)
