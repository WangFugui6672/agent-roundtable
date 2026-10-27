#!/usr/bin/env python3
"""Wait until an HTTP endpoint returns a successful response."""

from __future__ import annotations

import argparse
import time
import urllib.request


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(args.url, timeout=3) as response:
                if 200 <= response.status < 300:
                    return
        except Exception:
            time.sleep(1)
    raise SystemExit(f"Timed out waiting for {args.url}")


if __name__ == "__main__":
    main()
