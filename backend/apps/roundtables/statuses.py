"""Shared roundtable status predicates.

Keeping these groups in one module prevents scheduling, controls, history and
retention from drifting when a new status is introduced.
"""

from __future__ import annotations

from apps.roundtables.models import Roundtable

IN_PROGRESS_STATUSES = frozenset(
    {
        Roundtable.Status.READY,
        Roundtable.Status.RUNNING,
        Roundtable.Status.PAUSED,
        Roundtable.Status.SUMMARIZING,
    }
)

TERMINAL_STATUSES = frozenset(
    {
        Roundtable.Status.COMPLETED,
        Roundtable.Status.FAILED,
        Roundtable.Status.ARCHIVED,
    }
)

READ_ONLY_STATUSES = frozenset(
    {
        Roundtable.Status.SUMMARIZING,
        *TERMINAL_STATUSES,
    }
)

AGENT_SPEAKING_STATUSES = frozenset(
    {
        Roundtable.Status.READY,
        Roundtable.Status.RUNNING,
    }
)

SUMMARY_STATUSES = frozenset(
    {
        Roundtable.Status.SUMMARIZING,
        Roundtable.Status.COMPLETED,
    }
)

NON_SCHEDULING_STATUSES = frozenset(
    {
        Roundtable.Status.PAUSED,
        *READ_ONLY_STATUSES,
    }
)


def can_speak(status: str) -> bool:
    return status in AGENT_SPEAKING_STATUSES


def is_terminal(status: str) -> bool:
    return status in TERMINAL_STATUSES


def is_read_only(status: str) -> bool:
    return status in READ_ONLY_STATUSES
