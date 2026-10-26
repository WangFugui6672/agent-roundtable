"""REST endpoints. Errors use the envelope from ``roundtable.exceptions``."""

from __future__ import annotations

import uuid

from django.db import transaction
from rest_framework import status
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.roundtables.models import AgentProfile, GuestSession, Roundtable, RoundtableAgent
from apps.roundtables.protocol import iso8601_millis
from apps.roundtables.serializers import (
    AgentProfileSerializer,
    RoundtableCreateSerializer,
    RoundtableSerializer,
)
from roundtable.exceptions import GuestSessionRequired, RoundtableNotFound

GUEST_SESSION_HEADER = "X-Guest-Session"


def resolve_guest_session(request: Request) -> GuestSession:
    raw = request.headers.get(GUEST_SESSION_HEADER)
    if not raw:
        raise GuestSessionRequired(message="请求缺少 X-Guest-Session 头。")
    try:
        session_id = uuid.UUID(raw)
    except ValueError as exc:
        raise GuestSessionRequired(message="匿名会话标识格式不正确。") from exc
    session = GuestSession.objects.filter(id=session_id).first()
    if session is None:
        raise GuestSessionRequired(message="匿名会话不存在。")
    session.save(update_fields=["last_seen_at"])
    return session


class HealthView(APIView):
    def get(self, request: Request) -> Response:
        return Response({"status": "ok", "service": "agent-roundtable"})


class GuestSessionCreateView(APIView):
    def post(self, request: Request) -> Response:
        session = GuestSession.objects.create(id=uuid.uuid4())
        return Response(
            {"id": str(session.id), "created_at": iso8601_millis(session.created_at)},
            status=status.HTTP_201_CREATED,
        )


class AgentProfileListView(APIView):
    def get(self, request: Request) -> Response:
        profiles = AgentProfile.objects.all()
        return Response(AgentProfileSerializer(profiles, many=True).data)


class RoundtableListCreateView(APIView):
    def post(self, request: Request) -> Response:
        session = resolve_guest_session(request)
        body = RoundtableCreateSerializer(data=request.data)
        body.is_valid(raise_exception=True)

        profiles = list(
            AgentProfile.objects.filter(id__in=body.validated_data["agent_profile_ids"])
        )
        by_id = {profile.id: profile for profile in profiles}

        with transaction.atomic():
            roundtable = Roundtable.objects.create(
                id=uuid.uuid4(),
                guest_session=session,
                topic=body.validated_data["topic"],
            )
            for position, profile_id in enumerate(body.validated_data["agent_profile_ids"]):
                RoundtableAgent.objects.create(
                    id=uuid.uuid4(),
                    roundtable=roundtable,
                    agent_profile=by_id[profile_id],
                    position=position,
                )

        roundtable.refresh_from_db()
        return Response(RoundtableSerializer(roundtable).data, status=status.HTTP_201_CREATED)


class RoundtableDetailView(APIView):
    def get(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        roundtable = (
            Roundtable.objects.filter(id=roundtable_id, guest_session=session)
            .prefetch_related("agents__agent_profile")
            .first()
        )
        if roundtable is None:
            raise RoundtableNotFound()
        return Response(RoundtableSerializer(roundtable).data)
