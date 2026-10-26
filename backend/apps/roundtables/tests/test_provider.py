"""Provider metadata snapshot tests (Issue #3, docs/protocol.md 2.5/2.6)."""

from __future__ import annotations

import uuid

import pytest

from apps.roundtables.models import GuestSession, Roundtable

TOPIC = "该不该把验证周期压缩到两周？"
PROVIDER = {
    "kind": "deepseek",
    "base_url": "https://api.deepseek.com/v1",
    "model": "deepseek-chat",
}

pytestmark = pytest.mark.django_db


@pytest.fixture
def guest_session() -> GuestSession:
    return GuestSession.objects.create(id=uuid.uuid4())


@pytest.fixture
def guest_headers(guest_session: GuestSession) -> dict[str, str]:
    return {"HTTP_X_GUEST_SESSION": str(guest_session.id)}


def payload(agent_profiles, provider=None, **overrides) -> dict:
    body = {
        "topic": TOPIC,
        "agent_profile_ids": [str(profile.id) for profile in agent_profiles],
    }
    if provider is not None:
        body["provider"] = provider
    body.update(overrides)
    return body


def create(api_client, headers, agent_profiles, provider=None, **overrides):
    return api_client.post(
        "/api/v1/roundtables",
        payload(agent_profiles, provider, **overrides),
        format="json",
        **headers,
    )


def test_creates_roundtable_with_provider_metadata(api_client, guest_headers, agent_profiles):
    response = create(api_client, guest_headers, agent_profiles, PROVIDER)

    assert response.status_code == 201
    body = response.json()
    assert body["provider"] == PROVIDER

    roundtable = Roundtable.objects.get(id=body["id"])
    assert roundtable.provider_kind == "deepseek"
    assert roundtable.provider_base_url == "https://api.deepseek.com/v1"
    assert roundtable.provider_model == "deepseek-chat"


def test_creates_roundtable_without_provider(api_client, guest_headers, agent_profiles):
    response = create(api_client, guest_headers, agent_profiles)

    assert response.status_code == 201
    assert response.json()["provider"] is None
    roundtable = Roundtable.objects.get(id=response.json()["id"])
    assert roundtable.provider_kind == ""
    assert roundtable.provider_base_url == ""
    assert roundtable.provider_model == ""


def test_accepts_explicit_null_provider(api_client, guest_headers, agent_profiles):
    body = payload(agent_profiles)
    body["provider"] = None

    response = api_client.post("/api/v1/roundtables", body, format="json", **guest_headers)

    assert response.status_code == 201
    assert response.json()["provider"] is None


def test_normalizes_trailing_slash_in_base_url(api_client, guest_headers, agent_profiles):
    response = create(
        api_client,
        guest_headers,
        agent_profiles,
        {**PROVIDER, "base_url": "https://api.deepseek.com/v1/"},
    )

    assert response.status_code == 201
    assert response.json()["provider"]["base_url"] == "https://api.deepseek.com/v1"


def test_rejects_api_key_in_provider_metadata(api_client, guest_headers, agent_profiles):
    response = create(
        api_client,
        guest_headers,
        agent_profiles,
        {**PROVIDER, "api_key": "sk-should-never-arrive"},
    )

    assert response.status_code == 400
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    assert "API Key" in body["error"]["message"]
    assert "sk-should-never-arrive" not in response.content.decode()
    assert Roundtable.objects.count() == 0


def test_rejects_api_key_at_top_level(api_client, guest_headers, agent_profiles):
    response = create(api_client, guest_headers, agent_profiles, api_key="sk-should-never-arrive")

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "validation_error"
    assert Roundtable.objects.count() == 0


@pytest.mark.parametrize(
    ("provider", "reason"),
    [
        ({**PROVIDER, "kind": "openai"}, "unknown kind"),
        ({**PROVIDER, "base_url": "ftp://api.deepseek.com/v1"}, "non-http scheme"),
        ({**PROVIDER, "base_url": "not-a-url"}, "unparsable url"),
        ({**PROVIDER, "base_url": ""}, "empty base_url"),
        ({**PROVIDER, "model": "  "}, "blank model"),
    ],
)
def test_rejects_invalid_provider_metadata(
    api_client, guest_headers, agent_profiles, provider, reason
):
    response = create(api_client, guest_headers, agent_profiles, provider)

    assert response.status_code == 400, reason
    assert response.json()["error"]["code"] == "validation_error", reason
    assert Roundtable.objects.count() == 0, reason


def test_rejects_provider_without_required_fields(api_client, guest_headers, agent_profiles):
    response = create(api_client, guest_headers, agent_profiles, {"kind": "qwen"})

    assert response.status_code == 400
    details = response.json()["error"]["details"]
    assert set(details["provider"]) == {"base_url", "model"}


def test_detail_snapshot_includes_provider(api_client, guest_headers, agent_profiles):
    created = create(api_client, guest_headers, agent_profiles, PROVIDER).json()

    response = api_client.get(f"/api/v1/roundtables/{created['id']}", **guest_headers)

    assert response.status_code == 200
    assert response.json()["provider"] == PROVIDER


def test_provider_snapshot_never_contains_secret_fields(api_client, guest_headers, agent_profiles):
    created = create(api_client, guest_headers, agent_profiles, PROVIDER).json()

    assert set(created["provider"]) == {"kind", "base_url", "model"}
