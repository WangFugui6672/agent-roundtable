from __future__ import annotations

from django.urls import path

from apps.roundtables.views import (
    AgentProfileListView,
    GuestSessionCreateView,
    RoundtableDetailView,
    RoundtableListCreateView,
)

urlpatterns = [
    path("guest-sessions", GuestSessionCreateView.as_view(), name="guest-session-create"),
    path("agent-profiles", AgentProfileListView.as_view(), name="agent-profile-list"),
    path("roundtables", RoundtableListCreateView.as_view(), name="roundtable-list-create"),
    path(
        "roundtables/<uuid:roundtable_id>",
        RoundtableDetailView.as_view(),
        name="roundtable-detail",
    ),
]
