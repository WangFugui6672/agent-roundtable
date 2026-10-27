"""Non-destructive message annotations."""

from __future__ import annotations

from rest_framework.exceptions import ValidationError

from apps.roundtables.message_validation import is_valid_agent_view
from apps.roundtables.models import Message, Roundtable


def set_key_point(
    roundtable: Roundtable,
    message_id: str,
    is_key_point: bool,
) -> Message:
    message = (
        Message.objects.filter(
            id=message_id,
            roundtable=roundtable,
        )
        .select_related("roundtable_agent__agent_profile")
        .first()
    )
    if message is None:
        raise ValidationError({"message_id": "消息不存在或不属于当前圆桌。"})
    if not is_valid_agent_view(message):
        raise ValidationError({"message_id": "只能把有效 AI 观点标记为关键观点。"})
    if message.is_key_point != is_key_point:
        message.is_key_point = is_key_point
        message.save(update_fields=["is_key_point"])
    return message
