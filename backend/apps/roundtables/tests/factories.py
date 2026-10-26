from __future__ import annotations

import uuid

from apps.roundtables.models import AgentProfile

#: Mirrors apps/roundtables/migrations/0002_seed_agent_profiles.py. Tests create
#: their own copy so they never depend on `transaction=True` flush behaviour or
#: on test ordering.
PRESETS = [
    {
        "id": uuid.UUID("11111111-1111-4111-8111-111111111111"),
        "key": "advocate",
        "name": "方案派",
        "sort_order": 0,
    },
    {
        "id": uuid.UUID("22222222-2222-4222-8222-222222222222"),
        "key": "skeptic",
        "name": "质疑派",
        "sort_order": 1,
    },
    {
        "id": uuid.UUID("33333333-3333-4333-8333-333333333333"),
        "key": "experience",
        "name": "体验派",
        "sort_order": 2,
    },
]


def create_presets() -> list[AgentProfile]:
    profiles = []
    for preset in PRESETS:
        profile, _ = AgentProfile.objects.update_or_create(
            id=preset["id"],
            defaults={
                "key": preset["key"],
                "name": preset["name"],
                "tagline": f"{preset['name']}的定位。",
                "expertise": "测试用专长",
                "goal": "测试用目标",
                "default_stance": "测试用默认立场",
                "style": "测试用表达风格",
                "banned_behaviors": ["测试用禁止行为"],
                "max_reply_chars": 180,
                "sort_order": preset["sort_order"],
            },
        )
        profiles.append(profile)
    return profiles
