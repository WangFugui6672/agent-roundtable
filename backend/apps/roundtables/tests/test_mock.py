"""Seed data and Mock script invariants."""

from __future__ import annotations

import importlib
import uuid

import pytest
from django.apps import apps as django_apps

from apps.roundtables import mock
from apps.roundtables.models import AgentProfile, GuestSession, Roundtable, RoundtableAgent
from apps.roundtables.tests.factories import create_presets

pytestmark = pytest.mark.django_db


def test_seed_migration_creates_and_removes_the_three_presets():
    AgentProfile.objects.all().delete()
    migration = importlib.import_module("apps.roundtables.migrations.0002_seed_agent_profiles")

    migration.seed(django_apps, None)

    assert list(AgentProfile.objects.order_by("sort_order").values_list("key", flat=True)) == [
        "advocate",
        "skeptic",
        "experience",
    ]
    advocate = AgentProfile.objects.get(key="advocate")
    assert advocate.name == "方案派"
    assert advocate.goal
    assert advocate.default_stance
    assert advocate.max_reply_chars == 180

    migration.unseed(django_apps, None)
    assert AgentProfile.objects.count() == 0


def _room_with_agents(profile_order: list[AgentProfile]) -> Roundtable:
    session = GuestSession.objects.create(id=uuid.uuid4())
    room = Roundtable.objects.create(
        id=uuid.uuid4(),
        guest_session=session,
        topic="该不该把验证周期压缩到两周？",
    )
    for position, profile in enumerate(profile_order):
        RoundtableAgent.objects.create(
            id=uuid.uuid4(),
            roundtable=room,
            agent_profile=profile,
            position=position,
        )
    return room


def test_mock_roles_follow_agent_key_not_selection_order():
    profiles = create_presets()
    room = _room_with_agents([profiles[2], profiles[1], profiles[0]])
    agents = list(room.agents.select_related("agent_profile").order_by("position"))

    script = mock.build_mock_round(room, agents, round_number=1)

    messages = [
        payload["message"] for event_type, payload in script if event_type == "message.completed"
    ]
    assert [message["author"]["agent_key"] for message in messages] == [
        "advocate",
        "skeptic",
        "experience",
    ]
    assert [message["message_type"] for message in messages] == [
        "proposal",
        "challenge",
        "supplement",
    ]
    assert messages[1]["references"] == [messages[0]["id"]]
