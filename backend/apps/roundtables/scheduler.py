"""Deterministic first-round speaker selection."""

from __future__ import annotations

from collections.abc import Iterable, Sequence

from apps.roundtables.models import RoundtableAgent


def select_next_speaker(
    agents: Iterable[RoundtableAgent],
    preferred_ids: Sequence[str] = (),
) -> RoundtableAgent | None:
    """Pick a waiting Agent, honoring explicit user mentions first."""
    waiting = [agent for agent in agents if agent.state == RoundtableAgent.State.WAITING]
    by_id = {str(agent.id): agent for agent in waiting}
    for agent_id in preferred_ids:
        if agent_id in by_id:
            return by_id[agent_id]
    return min(waiting, key=lambda agent: agent.position, default=None)
