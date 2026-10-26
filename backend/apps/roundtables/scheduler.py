"""Deterministic first-round speaker selection."""

from __future__ import annotations

from collections.abc import Iterable

from apps.roundtables.models import RoundtableAgent


def select_next_speaker(agents: Iterable[RoundtableAgent]) -> RoundtableAgent | None:
    """Pick the next Agent who has not taken a turn in the current round."""
    waiting = (agent for agent in agents if agent.state == RoundtableAgent.State.WAITING)
    return min(waiting, key=lambda agent: agent.position, default=None)
