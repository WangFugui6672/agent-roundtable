"""Celery purge task and beat configuration contracts (PRD 9.1)."""

from __future__ import annotations

from unittest.mock import patch

from django.test import override_settings

from apps.roundtables.tasks import purge_expired_roundtables_task
from roundtable.celery import app


def test_purge_task_delegates_to_retention_service():
    with patch(
        "apps.roundtables.tasks.purge_expired_roundtables",
        return_value=7,
    ) as purge:
        result = purge_expired_roundtables_task.run()

    purge.assert_called_once_with()
    assert result == 7


@override_settings(
    CELERY_BROKER_URL="redis://127.0.0.1:6379/3",
    CELERY_TASK_ALWAYS_EAGER=True,
)
def test_celery_app_and_daily_beat_schedule_are_configured():
    assert app.conf.broker_url == "redis://127.0.0.1:6379/3"
    assert app.conf.task_always_eager is True
    assert app.conf.beat_schedule["purge-expired-roundtables"]["task"] == (
        "apps.roundtables.tasks.purge_expired_roundtables_task"
    )
