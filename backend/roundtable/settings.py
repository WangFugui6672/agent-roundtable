"""Django settings for Agent Roundtable.

Configuration comes from environment variables so that local development,
tests, and CI use the same settings module.
"""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import unquote, urlparse

BASE_DIR = Path(__file__).resolve().parent.parent


def load_dotenv(path: Path) -> None:
    """Minimal ``.env`` loader so local development needs no extra dependency."""
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


load_dotenv(BASE_DIR / ".env")


def env(name: str, default: str | None = None) -> str | None:
    return os.environ.get(name, default)


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


SECRET_KEY = env("DJANGO_SECRET_KEY", "dev-insecure-secret-key")
DEBUG = env_flag("DJANGO_DEBUG", default=False)
raw_hosts = env("DJANGO_ALLOWED_HOSTS") or "localhost,127.0.0.1"
ALLOWED_HOSTS = [host for host in raw_hosts.split(",") if host]

INSTALLED_APPS = [
    "daphne",
    "django.contrib.contenttypes",
    "rest_framework",
    "channels",
    "apps.roundtables",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "roundtable.urls"
TEMPLATES: list[dict[str, object]] = []

ASGI_APPLICATION = "roundtable.asgi.application"

REDIS_URL = env("REDIS_URL")
if REDIS_URL:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {"hosts": [REDIS_URL]},
        },
    }
else:
    # Unit tests and the single-process development server need only Postgres.
    CHANNEL_LAYERS = {
        "default": {"BACKEND": "channels.layers.InMemoryChannelLayer"},
    }
WSGI_APPLICATION = "roundtable.wsgi.application"

# WebSocket clients can replay persisted events inside this window. Older
# events are represented by the full room snapshot instead of a partial replay.
ROOM_EVENT_REPLAY_WINDOW_DAYS = max(
    1,
    int(env("ROOM_EVENT_REPLAY_WINDOW_DAYS", "90") or "90"),
)
ROUNDTABLE_RETENTION_DAYS = max(
    1,
    int(env("ROUNDTABLE_RETENTION_DAYS", "90") or "90"),
)

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

TIME_ZONE = "UTC"
USE_TZ = True

# --- Database -------------------------------------------------------------
# `DATABASE_URL` is the single source of truth. Tests point it at a dedicated
# database, CI provides a service container, docker-compose provides the dev one.
DEFAULT_DATABASE_URL = "postgres://roundtable:roundtable@127.0.0.1:5432/roundtable"


def parse_database_url(url: str) -> dict[str, object]:
    parsed = urlparse(url)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise ValueError(f"Unsupported DATABASE_URL scheme: {parsed.scheme}")
    return {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": unquote(parsed.path.lstrip("/")),
        "USER": unquote(parsed.username or ""),
        "PASSWORD": unquote(parsed.password or ""),
        "HOST": parsed.hostname or "127.0.0.1",
        "PORT": str(parsed.port or 5432),
        "CONN_MAX_AGE": 0,
    }


DATABASES = {"default": parse_database_url(env("DATABASE_URL", DEFAULT_DATABASE_URL) or "")}

# --- Django REST Framework ------------------------------------------------
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.AllowAny"],
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "EXCEPTION_HANDLER": "roundtable.exceptions.api_exception_handler",
    "UNAUTHENTICATED_USER": None,
}

# --- Logging --------------------------------------------------------------
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": "INFO"},
}
