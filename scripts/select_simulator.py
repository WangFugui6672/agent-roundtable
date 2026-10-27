#!/usr/bin/env python3
"""Print a stable available iPhone simulator UDID for xcodebuild."""

from __future__ import annotations

import json
import os
import re
import subprocess

BASE_IPHONE = re.compile(r"^iPhone \d+$")
ECONOMY_IPHONE = re.compile(r"^iPhone \d+e$")
SPECIAL_EDITIONS = ("Air", "Duo", "Fold", "Pro Max")


def version_key(runtime: str) -> tuple[int, ...]:
    numbers = re.findall(r"\d+", runtime.rsplit(".", 1)[-1])
    return tuple(int(number) for number in numbers)


def device_rank(name: str) -> int:
    """Prefer standard iPhone models over special editions for stable UI tests."""
    if BASE_IPHONE.fullmatch(name):
        return 3
    if ECONOMY_IPHONE.fullmatch(name):
        return 2
    if not any(edition in name for edition in SPECIAL_EDITIONS):
        return 1
    return 0


def select_device(
    runtimes: dict[str, list[dict[str, object]]],
    requested_name: str | None = None,
) -> str:
    candidates: list[tuple[int, tuple[int, ...], str, str]] = []
    for runtime, devices in runtimes.items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            name = str(device.get("name", ""))
            if not device.get("isAvailable", False) or not name.startswith("iPhone"):
                continue
            if "Duo" in name or "Fold" in name:
                continue
            if requested_name and name != requested_name:
                continue
            candidates.append(
                (
                    device_rank(name),
                    version_key(runtime),
                    name,
                    str(device["udid"]),
                )
            )

    if not candidates:
        suffix = f" named {requested_name!r}" if requested_name else ""
        raise LookupError(f"No available iPhone simulator{suffix}.")

    return max(candidates)[3]


def main() -> None:
    requested_id = os.environ.get("SIMULATOR_ID")
    if requested_id:
        print(requested_id)
        return

    requested_name = os.environ.get("SIMULATOR_NAME")
    output = subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        text=True,
    )
    try:
        print(select_device(json.loads(output)["devices"], requested_name))
    except LookupError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
