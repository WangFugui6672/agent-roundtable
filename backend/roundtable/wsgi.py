"""WSGI entrypoint (kept for management commands and tooling)."""

from __future__ import annotations

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "roundtable.settings")

application = get_wsgi_application()
