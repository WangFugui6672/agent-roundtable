package com.agentroundtable.core.turn

/**
 * Turn 失败的分类。
 *
 * 服务端会在 `agent.failed` 里给出 `retryable`，这里补一份本地判定，
 * 用于客户端自己发起的失败（网络、空回复等）以及界面上的重试入口。
 */
enum class FailureKind(val retryable: Boolean) {
    Timeout(true),
    RateLimited(true),
    Network(true),
    ServerError(true),
    EmptyReply(true),
    InvalidResponse(true),
    Unauthorized(false),
    InsufficientBalance(false),
    ModelNotFound(false),
    NotConfigured(false),
    Unknown(false),
    ;

    companion object {
        fun fromCode(code: String): FailureKind = when (code) {
            "provider_timeout" -> Timeout
            "provider_rate_limited" -> RateLimited
            "provider_network" -> Network
            "provider_server_error" -> ServerError
            "provider_empty_reply" -> EmptyReply
            "provider_invalid_response" -> InvalidResponse
            "provider_unauthorized" -> Unauthorized
            "provider_insufficient_balance" -> InsufficientBalance
            "provider_model_not_found" -> ModelNotFound
            "provider_not_configured" -> NotConfigured
            else -> Unknown
        }

        /** 服务端给出的 `retryable` 优先；缺失时退回本地分类。 */
        fun retryable(code: String, serverRetryable: Boolean?): Boolean =
            serverRetryable ?: fromCode(code).retryable
    }
}
