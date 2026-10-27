from __future__ import annotations

from django.urls import path

from apps.roundtables.views import (
    AgentProfileListView,
    GuestSessionCreateView,
    MessageReportCreateView,
    RoundtableDetailView,
    RoundtableEndView,
    RoundtableFollowUpView,
    RoundtableListCreateView,
    RoundtableMessageView,
    RoundtableNextTurnView,
    RoundtablePauseView,
    RoundtableResumeView,
    RoundtableSummaryView,
    RoundtableTurnFailView,
    RoundtableTurnPassView,
    RoundtableUserMessageView,
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
        "roundtables/<uuid:roundtable_id>/summary",
        RoundtableSummaryView.as_view(),
        name="roundtable-summary",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/follow-ups",
        RoundtableFollowUpView.as_view(),
        name="roundtable-follow-up",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/user-messages",
        RoundtableUserMessageView.as_view(),
        name="roundtable-user-message-create",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/messages/<uuid:message_id>/reports",
        MessageReportCreateView.as_view(),
        name="message-report-create",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/pause",
        RoundtablePauseView.as_view(),
        name="roundtable-pause",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/resume",
        RoundtableResumeView.as_view(),
        name="roundtable-resume",
    ),
    path(
        "roundtables/<uuid:roundtable_id>/end",
        RoundtableEndView.as_view(),
        name="roundtable-end",
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
    path(
        "roundtables/<uuid:roundtable_id>/turns/fail",
        RoundtableTurnFailView.as_view(),
        name="roundtable-turn-fail",
    ),
]
