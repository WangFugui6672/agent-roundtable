from __future__ import annotations

import pytest
from rest_framework.test import APIClient

from apps.roundtables.tests.factories import create_presets


@pytest.fixture
def api_client() -> APIClient:
    return APIClient()


@pytest.fixture
def agent_profiles():
    return create_presets()
