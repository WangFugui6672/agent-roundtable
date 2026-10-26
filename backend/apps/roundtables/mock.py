"""Deterministic stand-in for a hosted model.

The mock never calls a provider. It produces a fixed script so the client and
the event pipeline can be developed and tested without an API key. Content is
intentionally stable: tests assert on ordering and message shape, never on
model output quality.
"""

from __future__ import annotations

import uuid
from typing import Any

from apps.roundtables import protocol as p


def _message(
    *,
    agent,
    round_number: int,
    message_type: str,
    claim: str,
    body: str,
    stance: str | None = None,
    references: list[str] | None = None,
    challenge_target_agent_id: str | None = None,
    confidence: float,
) -> dict[str, Any]:
    return {
        "message": {
            "id": str(uuid.uuid4()),
            "turn_id": None,
            "round_number": round_number,
            "author": {
                "type": "agent",
                "roundtable_agent_id": str(agent.id),
                "agent_key": agent.agent_profile.key,
                "name": agent.agent_profile.name,
            },
            "message_type": message_type,
            "claim": claim,
            "body": body,
            "stance": stance,
            "references": references or [],
            "challenge_target_agent_id": challenge_target_agent_id,
            "confidence": confidence,
            "mentioned_agent_ids": [],
            "created_at": p.now_iso(),
        }
    }


def build_mock_round(room, agents, round_number: int) -> list[tuple[str, dict[str, Any]]]:
    """Return the ordered ``(event_type, payload)`` script for one mock round."""
    if len(agents) != 3:
        raise ValueError("Mock round requires exactly three participants.")

    by_key = {agent.agent_profile.key: agent for agent in agents}
    try:
        first, second, third = (
            by_key["advocate"],
            by_key["skeptic"],
            by_key["experience"],
        )
    except KeyError as exc:
        raise ValueError(f"Mock round requires the three preset agents, missing {exc}") from exc

    events: list[tuple[str, dict[str, Any]]] = [
        (
            p.ROUND_STARTED,
            {"round": round_number, "max_rounds": room.max_rounds, "topic": room.topic},
        ),
    ]

    proposal = _message(
        agent=first,
        round_number=round_number,
        message_type="proposal",
        claim="先用一个两周的验证性实验确认假设，再决定是否加大投入。",
        body=(
            "我建议把议题拆成一个两周内可验证的最小实验：写清假设、指标和停止条件。"
            "这样即使方向判断错了，也能用最低成本提前发现。"
        ),
        confidence=0.72,
    )
    challenge = _message(
        agent=second,
        round_number=round_number,
        message_type="challenge",
        claim="两周验证可能只是把决策成本推后，而不是降低。",
        body=(
            "反例是：验证指标由我们自己挑选，很容易得到想要的结论。"
            "建议先定义可以被否证的指标，并指定一名反方评审人。"
        ),
        stance="challenge",
        references=[proposal["message"]["id"]],
        challenge_target_agent_id=str(first.id) if round_number >= 2 else None,
        confidence=0.64,
    )
    supplement = _message(
        agent=third,
        round_number=round_number,
        message_type="supplement",
        claim="用户能感知的是等待和不确定，方案要先给出现在就能拿到的价值。",
        body=(
            "从体验上看，两周实验期间用户什么也拿不到。"
            "建议并行提供一个小而确定的价值点，让等待有回报。"
        ),
        stance="supplement",
        references=[proposal["message"]["id"]],
        confidence=0.58,
    )

    for agent, envelope in ((first, proposal), (second, challenge), (third, supplement)):
        events.append(
            (
                p.AGENT_THINKING,
                {"agent_id": str(agent.id), "agent_name": agent.agent_profile.name},
            )
        )
        events.append((p.AGENT_TYPING, {"agent_id": str(agent.id)}))
        events.append((p.MESSAGE_COMPLETED, envelope))

    events.append((p.ROUND_COMPLETED, {"round": round_number}))
    return events
