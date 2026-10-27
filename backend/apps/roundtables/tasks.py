"""Background tasks for data retention."""

from __future__ import annotations

from celery import shared_task

from apps.roundtables.services import purge_expired_roundtables


@shared_task(name="apps.roundtables.tasks.purge_expired_roundtables_task")
def purge_expired_roundtables_task() -> int:
    return purge_expired_roundtables()
