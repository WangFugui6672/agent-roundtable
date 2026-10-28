package com.agentroundtable.core.api

/**
 * 服务端错误信封中的稳定错误码。客户端按 [code] 分支，[message] 只用于展示。
 */
enum class ApiErrorCode(val wireValue: String) {
    GuestSessionRequired("guest_session_required"),
    RoundtableNotFound("roundtable_not_found"),
    ValidationError("validation_error"),
    ActiveRoundtableLimit("active_roundtable_limit"),
    MockDailyLimit("mock_daily_limit"),
    SummaryVersionConflict("summary_version_conflict"),
    ContainsSecret("contains_secret"),
    Unknown("");

    companion object {
        fun fromWire(value: String): ApiErrorCode =
            entries.firstOrNull { it.wireValue == value } ?: Unknown
    }
}

/** 一次请求的结果。失败携带稳定错误码与可直接展示的文案。 */
sealed interface ApiResult<out T> {
    data class Success<T>(val value: T) : ApiResult<T>

    data class Failure(
        val code: ApiErrorCode,
        val message: String,
        val httpStatus: Int,
    ) : ApiResult<Nothing>
}
