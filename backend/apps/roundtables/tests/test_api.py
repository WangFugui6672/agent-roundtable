"""Contract tests for the REST surface (docs/protocol.md)."""

from __future__ import annotations

import re
import uuid

import pytest

from apps.roundtables.models import GuestSession, Roundtable, RoundtableAgent

ISO_MILLIS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
TOPIC = "该不该把验证周期压缩到两周？"

pytestmark = pytest.mark.django_db


@pytest.fixture
def guest_session() -> GuestSession:
    return GuestSession.objects.create(id=uuid.uuid4())


@pytest.fixture
def guest_headers(guest_session: GuestSession) -> dict[str, str]:
    return {"HTTP_X_GUEST_SESSION": str(guest_session.id)}


def roundtable_payload(agent_profiles, topic: str = TOPIC, profile_ids=None) -> dict:
    ids = profile_ids if profile_ids is not None else [profile.id for profile in agent_profiles]
    return {"topic": topic, "agent_profile_ids": [str(profile_id) for profile_id in ids]}


def create_roundtable(api_client, headers, agent_profiles, topic: str = TOPIC):
    return api_client.post(
        "/api/v1/roundtables",
        roundtable_payload(agent_profiles, topic),
        format="json",
        **headers,
    )


def test_health(api_client):
    response = api_client.get("/api/v1/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_unknown_route_returns_json_error(api_client):
    response = api_client.get("/api/v1/does-not-exist")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


def test_creates_anonymous_guest_session(api_client):
    response = api_client.post("/api/v1/guest-sessions")

    assert response.status_code == 201
    body = response.json()
    uuid.UUID(body["id"])
    assert ISO_MILLIS.match(body["created_at"])


def test_lists_the_three_preset_agents(api_client, agent_profiles):
    response = api_client.get("/api/v1/agent-profiles")

    assert response.status_code == 200
    body = response.json()
    assert [agent["key"] for agent in body] == ["advocate", "skeptic", "experience"]
    assert all(agent["name"] for agent in body)
    assert all(agent["goal"] for agent in body)
    assert all(agent["default_stance"] for agent in body)


def test_creates_roundtable_with_three_participants(api_client, guest_headers, agent_profiles):
    response = create_roundtable(api_client, guest_headers, agent_profiles)

    assert response.status_code == 201
    body = response.json()
    uuid.UUID(body["id"])
    assert body["topic"] == TOPIC
    assert body["status"] == "ready"
    assert body["mode"] == "decision"
    assert body["max_rounds"] == 2
    assert body["current_round"] == 0
    assert body["last_sequence"] == 0
    assert ISO_MILLIS.match(body["created_at"])
    assert [agent["agent"]["key"] for agent in body["participants"]] == [
        "advocate",
        "skeptic",
        "experience",
    ]
    assert [agent["position"] for agent in body["participants"]] == [0, 1, 2]

    roundtable = Roundtable.objects.get(id=body["id"])
    assert roundtable.guest_session_id == uuid.UUID(guest_headers["HTTP_X_GUEST_SESSION"])
    assert RoundtableAgent.objects.filter(roundtable=roundtable).count() == 3


def test_roundtable_requires_guest_session(api_client, agent_profiles):
    response = api_client.post(
        "/api/v1/roundtables",
        roundtable_payload(agent_profiles),
        format="json",
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "guest_session_required"


def test_rejects_unknown_guest_session(api_client, agent_profiles):
    response = api_client.post(
        "/api/v1/roundtables",
        roundtable_payload(agent_profiles),
        format="json",
        HTTP_X_GUEST_SESSION=str(uuid.uuid4()),
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "guest_session_required"


@pytest.mark.parametrize(
    "selection",
    [
        pytest.param("only-two", id="two-agents"),
        pytest.param("duplicated", id="duplicate-agents"),
        pytest.param("missing", id="unknown-agent"),
    ],
)
def test_rejects_invalid_agent_selection(api_client, guest_headers, agent_profiles, selection):
    ids = [profile.id for profile in agent_profiles]
    if selection == "only-two":
        ids = ids[:2]
    elif selection == "duplicated":
        ids = [ids[0], ids[0], ids[1]]
    else:
        ids = [ids[0], ids[1], uuid.uuid4()]

    response = api_client.post(
        "/api/v1/roundtables",
        roundtable_payload(agent_profiles, profile_ids=ids),
        format="json",
        **guest_headers,
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"


@pytest.mark.parametrize(
    "topic",
    [
        pytest.param("", id="empty"),
        pytest.param("   ", id="whitespace"),
        pytest.param("x" * 501, id="too-long"),
    ],
)
def test_rejects_invalid_topic(api_client, guest_headers, agent_profiles, topic):
    response = api_client.post(
        "/api/v1/roundtables",
        roundtable_payload(agent_profiles, topic),
        format="json",
        **guest_headers,
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"


def test_reads_own_roundtable(api_client, guest_headers, agent_profiles):
    created = create_roundtable(api_client, guest_headers, agent_profiles).json()

    response = api_client.get(f"/api/v1/roundtables/{created['id']}", **guest_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == created["id"]
    assert len(body["participants"]) == 3


def test_hides_roundtable_from_other_guest_sessions(api_client, guest_headers, agent_profiles):
    created = create_roundtable(api_client, guest_headers, agent_profiles).json()

    response = api_client.get(
        f"/api/v1/roundtables/{created['id']}",
        HTTP_X_GUEST_SESSION=str(uuid.uuid4()),
    )
    assert response.status_code == 401

    other = GuestSession.objects.create(id=uuid.uuid4())
    response = api_client.get(
        f"/api/v1/roundtables/{created['id']}",
        HTTP_X_GUEST_SESSION=str(other.id),
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "roundtable_not_found"


def test_roundtable_detail_requires_guest_session(api_client, guest_headers, agent_profiles):
    created = create_roundtable(api_client, guest_headers, agent_profiles).json()

    response = api_client.get(f"/api/v1/roundtables/{created['id']}")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "guest_session_required"
