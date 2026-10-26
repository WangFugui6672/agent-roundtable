"""Discussion and creation limits shared by scheduling and REST commands."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

MAX_ACTIVE_ROUNDTABLES = 3
MAX_MOCK_ROUNDTABLES_PER_DAY = 10
MAX_ROUNDS = 2
MAX_AGENT_MESSAGES = 6
MAX_TURN_SECONDS = 60
MAX_DISCUSSION_SECONDS = 90
MAX_REPORTED_TOKENS = 2400

ACTIVE_STATUSES = frozenset({"ready", "running", "paused", "summarizing"})


def utc_day_bounds(now: datetime | None = None) -> tuple[datetime, datetime]:
    current = (now or datetime.now(tz=UTC)).astimezone(UTC)
    start = current.replace(hour=0, minute=0, second=0, microsecond=0)
    return start, start + timedelta(days=1)
