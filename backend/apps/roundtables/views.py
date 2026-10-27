"""REST endpoints. Errors use the envelope from ``roundtable.exceptions``."""

from __future__ import annotations

import uuid

from django.db import transaction
from rest_framework import status
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.roundtables.annotations import set_key_point
from apps.roundtables.budget import (
    ACTIVE_STATUSES,
    MAX_ACTIVE_ROUNDTABLES,
    MAX_MOCK_ROUNDTABLES_PER_DAY,
    utc_day_bounds,
)
from apps.roundtables.commands import TurnFailureCommand
from apps.roundtables.history import (
    delete_guest_session,
    list_roundtables,
    rotate_guest_session,
)
from apps.roundtables.models import (
    AgentProfile,
    GuestSession,
    RoundSummary,
    Roundtable,
    RoundtableAgent,
)
from apps.roundtables.protocol import iso8601_millis
from apps.roundtables.regeneration import request_regeneration
from apps.roundtables.serializers import (
    AgentProfileSerializer,
    FollowUpCreateSerializer,
    KeyPointUpdateSerializer,
    MessageCreateSerializer,
    MessageReportCreateSerializer,
    MessageReportSerializer,
    MessageSerializer,
    RoundSummaryCreateSerializer,
    RoundSummarySerializer,
    RoundtableCreateSerializer,
    RoundtableSerializer,
    TurnFailSerializer,
    TurnPassSerializer,
    TurnSerializer,
    UserMessageCreateSerializer,
)
from apps.roundtables.services import (
    create_follow_up,
    create_message,
    create_user_message,
    delete_roundtable,
    end_room,
    fail_turn,
    next_turn,
    pass_turn,
    pause_room,
    resume_room,
    submit_message_report,
    submit_summary,
)
from roundtable.exceptions import (
    ActiveRoundtableLimit,
    GuestSessionRequired,
    MockDailyLimit,
    RoundtableNotFound,
)

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


class GuestSessionRotateView(APIView):
    def post(self, request: Request) -> Response:
        session = resolve_guest_session(request)
        replacement = rotate_guest_session(session)
        return Response(
            {
                "id": str(replacement.id),
                "created_at": iso8601_millis(replacement.created_at),
            }
        )


class GuestSessionDeleteView(APIView):
    def delete(self, request: Request) -> Response:
        session = resolve_guest_session(request)
        delete_guest_session(session)
        return Response(status=status.HTTP_204_NO_CONTENT)


class AgentProfileListView(APIView):
    def get(self, request: Request) -> Response:
        profiles = AgentProfile.objects.all()
        return Response(AgentProfileSerializer(profiles, many=True).data)


class RoundtableListCreateView(APIView):
    def get(self, request: Request) -> Response:
        session = resolve_guest_session(request)
        rooms = list_roundtables(session)
        return Response(RoundtableSerializer(rooms, many=True).data)

    def post(self, request: Request) -> Response:
        session = resolve_guest_session(request)
        body = RoundtableCreateSerializer(data=request.data)
        body.is_valid(raise_exception=True)

        profiles = list(
            AgentProfile.objects.filter(id__in=body.validated_data["agent_profile_ids"])
        )
        by_id = {profile.id: profile for profile in profiles}
        provider = body.validated_data.get("provider") or {}

        with transaction.atomic():
            session = GuestSession.objects.select_for_update().get(id=session.id)
            active_count = Roundtable.objects.filter(
                guest_session=session,
                status__in=ACTIVE_STATUSES,
            ).count()
            if active_count >= MAX_ACTIVE_ROUNDTABLES:
                raise ActiveRoundtableLimit()

            if not provider:
                day_start, day_end = utc_day_bounds()
                mock_count = Roundtable.objects.filter(
                    guest_session=session,
                    provider_kind="",
                    created_at__gte=day_start,
                    created_at__lt=day_end,
                ).count()
                if mock_count >= MAX_MOCK_ROUNDTABLES_PER_DAY:
                    raise MockDailyLimit()

            roundtable = Roundtable.objects.create(
                id=uuid.uuid4(),
                guest_session=session,
                topic=body.validated_data["topic"],
                provider_kind=provider.get("kind", ""),
                provider_base_url=provider.get("base_url", ""),
                provider_model=provider.get("model", ""),
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

    def delete(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        result = delete_roundtable(str(roundtable_id), str(session.id))
        if result is None:
            raise RoundtableNotFound()
        return Response(status=status.HTTP_204_NO_CONTENT)


class RoundtableSummaryView(APIView):
    """Read or create/regenerate the structured conclusion."""

    def get(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        roundtable = Roundtable.objects.filter(
            id=roundtable_id,
            guest_session=session,
        ).first()
        if roundtable is None:
            raise RoundtableNotFound()
        summary = RoundSummary.objects.filter(roundtable=roundtable).first()
        return Response({"summary": RoundSummarySerializer(summary).data if summary else None})

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        roundtable = Roundtable.objects.filter(
            id=roundtable_id,
            guest_session=session,
        ).first()
        if roundtable is None:
            raise RoundtableNotFound()

        body = RoundSummaryCreateSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        result = submit_summary(
            str(roundtable.id),
            str(session.id),
            body.validated_data,
        )
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "roundtable": RoundtableSerializer(result.room).data,
                "summary": RoundSummarySerializer(result.summary).data,
                "events": result.events,
            },
            status=(status.HTTP_201_CREATED if result.created else status.HTTP_200_OK),
        )


class RoundtableFollowUpView(APIView):
    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        parent = Roundtable.objects.filter(
            id=roundtable_id,
            guest_session=session,
        ).first()
        if parent is None:
            raise RoundtableNotFound()
        body = FollowUpCreateSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        follow_up = create_follow_up(
            str(parent.id),
            str(session.id),
            body.validated_data["topic"],
        )
        if follow_up is None:
            raise RoundtableNotFound()
        return Response(
            RoundtableSerializer(follow_up).data,
            status=status.HTTP_201_CREATED,
        )


class RoundtableMessageView(APIView):
    """Persist one structured utterance produced by the iOS provider client."""

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        roundtable = Roundtable.objects.filter(id=roundtable_id, guest_session=session).first()
        if roundtable is None:
            raise RoundtableNotFound()

        body = MessageCreateSerializer(data=request.data, context={"roundtable": roundtable})
        body.is_valid(raise_exception=True)
        envelope = create_message(str(roundtable.id), str(session.id), body.validated_data)
        if envelope is None:
            raise RoundtableNotFound()

        return Response(envelope, status=status.HTTP_201_CREATED)


class RoundtableUserMessageView(APIView):
    """Persist a user message without impersonating a RoundtableAgent."""

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        roundtable = Roundtable.objects.filter(id=roundtable_id, guest_session=session).first()
        if roundtable is None:
            raise RoundtableNotFound()

        body = UserMessageCreateSerializer(data=request.data, context={"roundtable": roundtable})
        body.is_valid(raise_exception=True)
        result = create_user_message(
            str(roundtable.id),
            str(session.id),
            body.validated_data["body"],
            [str(agent_id) for agent_id in body.validated_data["mentioned_agent_ids"]],
        )
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "roundtable": RoundtableSerializer(result.room).data,
                "events": result.events,
            },
            status=status.HTTP_201_CREATED,
        )


class MessageReportCreateView(APIView):
    def post(
        self,
        request: Request,
        roundtable_id: uuid.UUID,
        message_id: uuid.UUID,
    ) -> Response:
        session = resolve_guest_session(request)
        body = MessageReportCreateSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        result = submit_message_report(
            str(roundtable_id),
            str(session.id),
            str(message_id),
            body.validated_data["reason"],
            body.validated_data["details"],
        )
        if result is None:
            raise RoundtableNotFound()
        return Response(
            MessageReportSerializer(result.report).data,
            status=(status.HTTP_201_CREATED if result.created else status.HTTP_200_OK),
        )


class MessageKeyPointUpdateView(APIView):
    def patch(
        self,
        request: Request,
        roundtable_id: uuid.UUID,
        message_id: uuid.UUID,
    ) -> Response:
        session = resolve_guest_session(request)
        room = Roundtable.objects.filter(
            id=roundtable_id,
            guest_session=session,
        ).first()
        if room is None:
            raise RoundtableNotFound()
        body = KeyPointUpdateSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        message = set_key_point(
            room,
            str(message_id),
            body.validated_data["is_key_point"],
        )
        return Response(MessageSerializer(message).data)


class MessageRegenerateView(APIView):
    def post(
        self,
        request: Request,
        roundtable_id: uuid.UUID,
        message_id: uuid.UUID,
    ) -> Response:
        session = resolve_guest_session(request)
        result = request_regeneration(
            str(roundtable_id),
            str(session.id),
            str(message_id),
        )
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "round": result.round,
                "turn": TurnSerializer(result.turn).data if result.turn else None,
                "replacement_message_id": (
                    str(result.replacement_message_id) if result.replacement_message_id else None
                ),
                "events": result.events,
            },
            status=status.HTTP_201_CREATED if result.created else status.HTTP_200_OK,
        )


class RoundtablePauseView(APIView):
    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        result = pause_room(str(roundtable_id), str(session.id))
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "roundtable": RoundtableSerializer(result.room).data,
                "events": result.events,
            }
        )


class RoundtableResumeView(APIView):
    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        result = resume_room(str(roundtable_id), str(session.id))
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "roundtable": RoundtableSerializer(result.room).data,
                "events": result.events,
            }
        )


class RoundtableEndView(APIView):
    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        result = end_room(str(roundtable_id), str(session.id))
        if result is None:
            raise RoundtableNotFound()
        return Response(
            {
                "roundtable": RoundtableSerializer(result.room).data,
                "events": result.events,
            }
        )


class RoundtableNextTurnView(APIView):
    """Reserve the next scheduled Agent for the first round."""

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        result = next_turn(str(roundtable_id), str(session.id))
        if result is None:
            raise RoundtableNotFound()
        round_number, turn, events = result
        return Response({"round": round_number, "turn": turn, "events": events})


class RoundtableTurnPassView(APIView):
    """Persist the scheduled Agent's explicit decision not to speak."""

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        body = TurnPassSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        envelope = pass_turn(
            str(roundtable_id),
            str(session.id),
            str(body.validated_data["turn_id"]),
            str(body.validated_data["roundtable_agent_id"]),
            body.validated_data.get("usage"),
        )
        if envelope is None:
            raise RoundtableNotFound()
        return Response(envelope, status=status.HTTP_201_CREATED)


class RoundtableTurnFailView(APIView):
    """Persist the scheduled Agent's Provider failure exactly once."""

    def post(self, request: Request, roundtable_id: uuid.UUID) -> Response:
        session = resolve_guest_session(request)
        body = TurnFailSerializer(data=request.data)
        body.is_valid(raise_exception=True)
        envelope = fail_turn(
            str(roundtable_id),
            str(session.id),
            TurnFailureCommand.from_validated(body.validated_data),
        )
        if envelope is None:
            raise RoundtableNotFound()
        return Response(envelope, status=status.HTTP_201_CREATED)
