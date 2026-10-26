from __future__ import annotations

from django.urls import path

from apps.roundtables.views import (
    AgentProfileListView,
    GuestSessionCreateView,
    RoundtableDetailView,
    RoundtableListCreateView,
    RoundtableMessageView,
    RoundtableNextTurnView,
    RoundtableTurnPassView,
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
    path(
        "roundtables/<uuid:roundtable_id>/messages",
        RoundtableMessageView.as_view(),
        name="roundtable-message-create",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/turns/next",
        RoundtableNextTurnView.as_view(),
        name="roundtable-next-turn",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/turns/pass",
        RoundtableTurnPassView.as_view(),
        name="roundtable-turn-pass",
    ),
]
