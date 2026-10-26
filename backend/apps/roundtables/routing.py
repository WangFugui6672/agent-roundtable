from __future__ import annotations

from django.urls import re_path

from apps.roundtables.consumers import RoundtableConsumer

websocket_urlpatterns = [
    re_path(
        r"^ws/v1/roundtables/(?P<roundtable_id>[0-9a-fA-F-]{36})/?$",
        RoundtableConsumer.as_asgi(),
    ),
]
