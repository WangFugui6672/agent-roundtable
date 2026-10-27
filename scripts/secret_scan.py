#!/usr/bin/env python3
"""Fail on tracked secrets and common generated artifacts."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "OpenAI-style key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
}

FORBIDDEN_PATHS = (
    re.compile(r"(^|/)\.env(?!\.example$)"),
    re.compile(r"(^|/)AgentRoundtable\.xcodeproj/"),
    re.compile(r"(^|/)AgentRoundtable/Info\.plist$"),
    re.compile(r"(^|/)\.build/"),
    re.compile(r"(^|/)DerivedData/"),
    re.compile(r"\.xcresult(/|$)"),
)


def repository_paths() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    )
    return [Path(raw.decode()) for raw in output.split(b"\0") if raw]


def main() -> None:
    findings: list[str] = []
    for path in repository_paths():
        normalized = path.as_posix()
        if any(pattern.search(normalized) for pattern in FORBIDDEN_PATHS):
            findings.append(f"{normalized}: generated or secret-bearing path is tracked")
            continue
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                findings.append(f"{normalized}: possible {label}")

    if findings:
        raise SystemExit("Secret scan failed:\n" + "\n".join(findings))
    print("Secret scan passed.")


if __name__ == "__main__":
    main()
