"""Typed command values shared by REST views and domain services."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class TurnFailureCommand:
    turn_id: str
    roundtable_agent_id: str
    failure_code: str
    message: str
    retryable: bool
    partial: str
    usage: dict[str, Any] | None

    @classmethod
    def from_validated(cls, data: dict[str, Any]) -> TurnFailureCommand:
        return cls(
            turn_id=str(data["turn_id"]),
            roundtable_agent_id=str(data["roundtable_agent_id"]),
            failure_code=data["failure_code"],
            message=data["message"],
            retryable=data["retryable"],
            partial=data.get("partial", ""),
            usage=data.get("usage"),
        )
