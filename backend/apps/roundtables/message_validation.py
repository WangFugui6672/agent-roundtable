"""Shared invariants for submitted Agent messages."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from rest_framework.exceptions import ValidationError

from apps.roundtables.models import Message, Roundtable, RoundtableAgent, Turn
from apps.roundtables.protocol import (
    BODY_HARD_MAX_CHARS,
    CLAIM_MAX_CHARS,
    MAX_REFERENCES,
)

VALID_VIEW_TYPES = frozenset(
    {
        Message.Type.PROPOSAL,
        Message.Type.SUPPORT,
        Message.Type.CHALLENGE,
        Message.Type.SUPPLEMENT,
        Message.Type.QUESTION,
    }
)
REVIEW_TYPES = frozenset(
    {
        Message.Type.SUPPORT,
        Message.Type.CHALLENGE,
        Message.Type.SUPPLEMENT,
        Message.Type.QUESTION,
    }
)
AGENT_MESSAGE_TYPES = frozenset(
    {
        Message.Type.PROPOSAL,
        Message.Type.SUPPORT,
        Message.Type.CHALLENGE,
        Message.Type.SUPPLEMENT,
        Message.Type.QUESTION,
        Message.Type.SUMMARY,
    }
)
VALID_STANCES = frozenset(REVIEW_TYPES)


def _wire_value(value: object) -> str:
    if hasattr(value, "value"):
        value = value.value
    return str(value or "")


def is_valid_agent_view(message: Message) -> bool:
    return (
        message.author_type == Message.AuthorType.AGENT
        and message.roundtable_agent_id is not None
        and message.message_type in VALID_VIEW_TYPES
        and bool(message.claim.strip())
        and bool(message.body.strip())
    )


def validate_agent_message(
    *,
    roundtable: Roundtable,
    agent: RoundtableAgent,
    turn: Turn,
    data: dict[str, Any],
) -> None:
    """Reject payloads that must never bypass the REST serializer."""
    references: Sequence[Any] = data.get("references") or []
    message_type = _wire_value(data.get("message_type"))
    stance = _wire_value(data.get("stance"))
    claim = _wire_value(data.get("claim")).strip()
    body = _wire_value(data.get("body")).strip()

    if message_type not in AGENT_MESSAGE_TYPES:
        raise ValidationError({"message_type": "Agent 发言类型不合法。"})
    if stance and stance not in VALID_STANCES:
        raise ValidationError({"stance": "立场必须是 support、challenge、supplement 或 question。"})
    if not claim:
        raise ValidationError({"claim": "主张不能为空。"})
    if len(claim) > CLAIM_MAX_CHARS:
        raise ValidationError({"claim": f"主张不能超过 {CLAIM_MAX_CHARS} 字。"})
    if not body:
        raise ValidationError({"body": "正文不能为空。"})
    if len(body) > min(agent.agent_profile.max_reply_chars, BODY_HARD_MAX_CHARS):
        raise ValidationError({"body": f"正文不能超过 {agent.agent_profile.max_reply_chars} 字。"})
    data["claim"] = claim
    data["body"] = body
    data["stance"] = stance

    confidence = data.get("confidence")
    if confidence is not None:
        try:
            confidence_value = float(confidence)
        except (TypeError, ValueError) as exc:
            raise ValidationError({"confidence": "置信度必须是 0 到 1 之间的数字。"}) from exc
        if not 0 <= confidence_value <= 1:
            raise ValidationError({"confidence": "置信度必须是 0 到 1 之间的数字。"})
        data["confidence"] = confidence_value

    if len(references) > MAX_REFERENCES:
        raise ValidationError({"references": f"最多引用 {MAX_REFERENCES} 条消息。"})
    if turn.round_number >= 2:
        if message_type not in REVIEW_TYPES:
            raise ValidationError(
                {
                    "message_type": (
                        "第二轮发言类型必须是 support、challenge、supplement 或 question。"
                    )
                }
            )
        if stance not in REVIEW_TYPES:
            raise ValidationError(
                {"stance": "第二轮立场必须是 support、challenge、supplement 或 question。"}
            )
        if message_type != stance:
            raise ValidationError({"stance": "第二轮发言类型与立场必须一致。"})
    if turn.round_number >= 2 and not references:
        raise ValidationError({"references": "第二轮 Agent 发言必须引用已有观点。"})
    if len(set(references)) != len(references):
        raise ValidationError({"references": "引用消息不能重复。"})
    if not references:
        return

    referenced_messages = list(
        Message.objects.filter(roundtable=roundtable, id__in=references).select_related(
            "roundtable_agent",
            "turn",
        )
    )
    if len(referenced_messages) != len(references):
        raise ValidationError({"references": "引用的消息不存在或不属于此圆桌。"})
    if turn.round_number >= 2 and any(
        message.roundtable_agent_id == agent.id for message in referenced_messages
    ):
        raise ValidationError({"references": "第二轮不能引用自己的观点。"})
    if turn.round_number >= 2 and any(
        not is_valid_agent_view(message) for message in referenced_messages
    ):
        raise ValidationError({"references": "第二轮只能引用有效的 Agent 观点。"})
    if turn.round_number >= 2 and any(
        message.round_number > turn.round_number
        or (
            message.round_number == turn.round_number
            and (message.turn_id is None or message.turn.created_at >= turn.created_at)
        )
        for message in referenced_messages
    ):
        raise ValidationError({"references": "第二轮只能引用更早产生的观点。"})

    challenge_target_id = data.get("challenge_target_agent_id")
    if turn.round_number >= 2:
        if stance == Message.Stance.CHALLENGE and challenge_target_id is None:
            raise ValidationError({"challenge_target_agent_id": "质疑立场必须指定挑战对象。"})
        if stance != Message.Stance.CHALLENGE and challenge_target_id is not None:
            raise ValidationError({"challenge_target_agent_id": "只有质疑立场可以指定挑战对象。"})
        if challenge_target_id is not None:
            target_id = str(challenge_target_id)
            if target_id == str(agent.id):
                raise ValidationError({"challenge_target_agent_id": "不能挑战自己。"})
            if not RoundtableAgent.objects.filter(
                id=challenge_target_id,
                roundtable=roundtable,
            ).exists():
                raise ValidationError({"challenge_target_agent_id": "挑战对象不属于此圆桌。"})
            referenced_agent_ids = {
                str(message.roundtable_agent_id) for message in referenced_messages
            }
            if target_id not in referenced_agent_ids:
                raise ValidationError(
                    {"challenge_target_agent_id": "挑战对象必须是被引用观点的作者。"}
                )
