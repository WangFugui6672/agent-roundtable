"""Release configuration tests for deployment-sensitive Django settings."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[3]


def channel_layer_backend(**overrides: str) -> str:
    env = os.environ.copy()
    env.pop("REDIS_URL", None)
    env.update(overrides)
    env["DJANGO_SETTINGS_MODULE"] = "roundtable.settings"
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "from django.conf import settings; "
                "print(settings.CHANNEL_LAYERS['default']['BACKEND'])"
            ),
        ],
        cwd=BACKEND_DIR,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def celery_broker_url(**overrides: str) -> str:
    env = os.environ.copy()
    env.pop("REDIS_URL", None)
    env.pop("CELERY_BROKER_URL", None)
    env.update(overrides)
    env["DJANGO_SETTINGS_MODULE"] = "roundtable.settings"
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            ("from django.conf import settings; print(settings.CELERY_BROKER_URL)"),
        ],
        cwd=BACKEND_DIR,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def test_local_tests_use_in_memory_channel_layer_without_redis() -> None:
    assert channel_layer_backend() == "channels.layers.InMemoryChannelLayer"


def test_redis_url_selects_cross_process_channel_layer() -> None:
    assert (
        channel_layer_backend(REDIS_URL="redis://127.0.0.1:6379/0")
        == "channels_redis.core.RedisChannelLayer"
    )


def test_explicit_celery_broker_overrides_redis_channel_url() -> None:
    assert (
        celery_broker_url(
            REDIS_URL="redis://127.0.0.1:6379/0",
            CELERY_BROKER_URL="redis://127.0.0.1:6379/1",
        )
        == "redis://127.0.0.1:6379/1"
    )
