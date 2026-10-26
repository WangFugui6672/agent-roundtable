from __future__ import annotations

from django.urls import include, path

from apps.roundtables.views import HealthView

urlpatterns = [
    path("api/v1/health", HealthView.as_view(), name="health"),
    path("api/v1/", include("apps.roundtables.urls")),
]

handler404 = "roundtable.exceptions.not_found"
handler500 = "roundtable.exceptions.server_error"
