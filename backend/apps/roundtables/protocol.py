"""Wire format helpers shared by REST serializers and the WebSocket consumer.

Timestamps are ISO 8601 in UTC with exactly millisecond precision, e.g.
``2026-10-26T01:02:03.456Z``. Both Django and the iOS client rely on that
single format, so `tests/test_protocol.py` pins it.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

# --- Event types (docs/protocol.md) ---------------------------------------
ROOM_JOINED = "room.joined"
ROUND_STARTED = "round.started"
AGENT_THINKING = "agent.thinking"
AGENT_TYPING = "agent.typing"
MESSAGE_COMPLETED = "message.completed"
ROUND_COMPLETED = "round.completed"

#: ``room.joined`` is an ephemeral snapshot, not a log entry, so it must never
#: move the client's resume cursor.
EPHEMERAL_SEQUENCE = 0

#: Message limits shared with the client (docs/protocol.md 2.7).
CLAIM_MAX_CHARS = 80
DEFAULT_CONFIDENCE = 0.6
MAX_REFERENCES = 3
BODY_HARD_MAX_CHARS = 2000

#: Client -> server command that plays one scripted mock round.
#: TODO(#5): the turn scheduler replaces this bridge; clients stop sending it.
MOCK_RUN = "mock.run"


def iso8601_millis(value: datetime) -> str:
    """Serialize a datetime as UTC ISO 8601 with milliseconds and a ``Z`` suffix."""
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def now_iso() -> str:
    return iso8601_millis(datetime.now(tz=UTC))


def make_envelope(
    *,
    event_id: str,
    room_id: str,
    sequence: int,
    event_type: str,
    payload: dict[str, object],
    created_at: str | None = None,
) -> dict[str, object]:
    return {
        "event_id": event_id,
        "room_id": room_id,
        "sequence": sequence,
        "created_at": created_at or now_iso(),
        "event_type": event_type,
        "payload": payload,
    }


def new_event_id() -> str:
    return str(uuid.uuid4())
