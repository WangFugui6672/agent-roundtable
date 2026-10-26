from __future__ import annotations

from datetime import UTC, datetime

from apps.roundtables.protocol import iso8601_millis


def test_iso8601_millis_pins_the_wire_format():
    value = datetime(2026, 10, 26, 1, 2, 3, 456789, tzinfo=UTC)

    assert iso8601_millis(value) == "2026-10-26T01:02:03.456Z"


def test_iso8601_millis_converts_to_utc():
    value = datetime(2026, 10, 26, 9, 2, 3, tzinfo=UTC).astimezone()

    assert iso8601_millis(value).endswith("Z")
