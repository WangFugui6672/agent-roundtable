"""Uniform API error envelope.

Every non-2xx JSON response looks like::

    {"error": {"code": "validation_error", "message": "...", "details": {...}}}

The iOS client decodes this shape instead of inventing per-endpoint handling.
"""

from __future__ import annotations

from typing import Any

from django.http import JsonResponse
from rest_framework import exceptions, status
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler


class APIError(exceptions.APIException):
    """Base class for errors that carry a stable machine readable code."""

    status_code = status.HTTP_400_BAD_REQUEST
    default_detail = "请求无法处理。"
    default_code = "bad_request"

    def __init__(self, code: str | None = None, message: str | None = None) -> None:
        self.code = code or self.default_code
        super().__init__(detail=message or self.default_detail, code=self.code)


class GuestSessionRequired(APIError):
    status_code = status.HTTP_401_UNAUTHORIZED
    default_code = "guest_session_required"
    default_detail = "缺少或无效的匿名会话。"


class RoundtableNotFound(APIError):
    status_code = status.HTTP_404_NOT_FOUND
    default_code = "roundtable_not_found"
    default_detail = "圆桌不存在。"


class ActiveRoundtableLimit(APIError):
    status_code = status.HTTP_429_TOO_MANY_REQUESTS
    default_code = "active_roundtable_limit"
    default_detail = "同一匿名会话最多同时保留 3 个进行中的圆桌。"


class MockDailyLimit(APIError):
    status_code = status.HTTP_429_TOO_MANY_REQUESTS
    default_code = "mock_daily_limit"
    default_detail = "Mock 模式每个匿名会话每天最多创建 10 个圆桌。"


class SummaryVersionConflict(APIError):
    status_code = status.HTTP_409_CONFLICT
    default_code = "summary_version_conflict"
    default_detail = "结论已被其他生成结果更新，请刷新后重试。"


def _flatten(detail: Any) -> Any:
    if isinstance(detail, dict):
        return {key: _flatten(value) for key, value in detail.items()}
    if isinstance(detail, list):
        return [_flatten(item) for item in detail]
    return str(detail)


def _first_message(detail: Any) -> str:
    if isinstance(detail, dict):
        for value in detail.values():
            return _first_message(value)
        return "请求无法处理。"
    if isinstance(detail, list):
        return _first_message(detail[0]) if detail else "请求无法处理。"
    return str(detail)


def _error_response(status_code: int, code: str, message: str) -> JsonResponse:
    return JsonResponse(
        {"error": {"code": code, "message": message, "details": {}}},
        status=status_code,
    )


def not_found(request: Any, exception: Exception) -> JsonResponse:
    return _error_response(status.HTTP_404_NOT_FOUND, "not_found", "请求的资源不存在。")


def server_error(request: Any) -> JsonResponse:
    return _error_response(
        status.HTTP_500_INTERNAL_SERVER_ERROR, "server_error", "服务器内部错误。"
    )


def api_exception_handler(exc: Exception, context: dict[str, Any]) -> Response:
    response = drf_exception_handler(exc, context)
    if response is None:
        return Response(
            {"error": {"code": "server_error", "message": "服务器内部错误。", "details": {}}},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    code = getattr(exc, "code", None) or getattr(exc, "default_code", None) or "error"
    if isinstance(exc, exceptions.ValidationError):
        code = "validation_error"

    response.data = {
        "error": {
            "code": code,
            "message": str(exc.detail) if isinstance(exc, APIError) else _first_message(exc.detail),
            "details": _flatten(getattr(exc, "detail", {})),
        }
    }
    return response
