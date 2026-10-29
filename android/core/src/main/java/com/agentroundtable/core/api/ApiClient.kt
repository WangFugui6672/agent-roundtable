package com.agentroundtable.core.api

import com.agentroundtable.core.model.AgentProfile
import com.agentroundtable.core.model.GuestSession
import com.agentroundtable.core.model.ProviderMetadata
import com.agentroundtable.core.model.RoundSummarySubmission
import com.agentroundtable.core.model.Roundtable
import com.agentroundtable.core.model.SummaryEnvelope
import com.agentroundtable.core.summary.RoundSummaryResponse
import com.agentroundtable.core.turn.ControlResponse
import com.agentroundtable.core.turn.FailTurnRequest
import com.agentroundtable.core.turn.MessageSubmission
import com.agentroundtable.core.turn.NextTurnResponse
import com.agentroundtable.core.turn.PassTurnRequest
import com.agentroundtable.core.turn.SubmitMessageRequest
import com.agentroundtable.core.turn.UserMessageRequest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 创建圆桌的请求体。Provider 省略表示 Mock 演示。 */
@Serializable
data class CreateRoundtableRequest(
    val topic: String,
    @SerialName("agent_profile_ids") val agentProfileIds: List<String>,
    val provider: ProviderMetadata? = null,
)

@Serializable
private data class ErrorEnvelope(val error: ErrorBody)

@Serializable
private data class ErrorBody(
    val code: String,
    val message: String,
)

/**
 * Django REST 接口的客户端。
 *
 * 这里是协议层唯一知道 URL 形状的地方；上层只关心 [ApiResult]。
 */
class ApiClient(
    private val baseUrl: String,
    private val transport: HttpTransport,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    suspend fun createGuestSession(): ApiResult<GuestSession> =
        call(
            path = "/api/v1/guest-sessions",
            method = "POST",
            decode = { json.decodeFromString<GuestSession>(it) },
        )

    suspend fun listAgentProfiles(): ApiResult<List<AgentProfile>> =
        call(
            path = "/api/v1/agent-profiles",
            method = "GET",
            decode = { json.decodeFromString<List<AgentProfile>>(it) },
        )

    suspend fun listRoundtables(sessionId: String): ApiResult<List<Roundtable>> =
        call(
            path = "/api/v1/roundtables",
            method = "GET",
            sessionId = sessionId,
            decode = { json.decodeFromString<List<Roundtable>>(it) },
        )

    suspend fun createRoundtable(
        sessionId: String,
        topic: String,
        agentProfileIds: List<String>,
        provider: ProviderMetadata? = null,
    ): ApiResult<Roundtable> =
        call(
            path = "/api/v1/roundtables",
            method = "POST",
            sessionId = sessionId,
            body = json.encodeToString(
                CreateRoundtableRequest(topic, agentProfileIds, provider),
            ),
            decode = { json.decodeFromString<Roundtable>(it) },
        )

    suspend fun nextTurn(sessionId: String, roundtableId: String): ApiResult<NextTurnResponse> =
        call(
            path = "/api/v1/roundtables/$roundtableId/turns/next",
            method = "POST",
            sessionId = sessionId,
            body = "",
            decode = { json.decodeFromString<NextTurnResponse>(it) },
        )

    suspend fun submitMessage(
        sessionId: String,
        roundtableId: String,
        submission: MessageSubmission,
    ): ApiResult<Unit> = call(
        path = "/api/v1/roundtables/$roundtableId/messages",
        method = "POST",
        sessionId = sessionId,
        body = json.encodeToString(
            SubmitMessageRequest(
                turnId = submission.turnId,
                roundtableAgentId = submission.roundtableAgentId,
                messageType = submission.messageType,
                claim = submission.claim,
                body = submission.body,
                stance = submission.stance,
                references = submission.references,
                challengeTargetAgentId = submission.challengeTargetAgentId,
                confidence = submission.confidence,
            ),
        ),
        decode = { },
    )

    suspend fun passTurn(
        sessionId: String,
        roundtableId: String,
        turnId: String,
        roundtableAgentId: String,
    ): ApiResult<Unit> = call(
        path = "/api/v1/roundtables/$roundtableId/turns/pass",
        method = "POST",
        sessionId = sessionId,
        body = json.encodeToString(PassTurnRequest(turnId, roundtableAgentId)),
        decode = { },
    )

    suspend fun failTurn(
        sessionId: String,
        roundtableId: String,
        turnId: String,
        roundtableAgentId: String,
        failureCode: String,
        message: String,
        retryable: Boolean,
        partial: String? = null,
    ): ApiResult<Unit> = call(
        path = "/api/v1/roundtables/$roundtableId/turns/fail",
        method = "POST",
        sessionId = sessionId,
        body = json.encodeToString(
            FailTurnRequest(turnId, roundtableAgentId, failureCode, message, retryable, partial),
        ),
        decode = { },
    )

    /** 暂停圆桌。已暂停时重复调用是幂等的。 */
    suspend fun pauseRoundtable(sessionId: String, roundtableId: String): ApiResult<ControlResponse> =
        control(sessionId, roundtableId, "pause")

    /** 继续圆桌。 */
    suspend fun resumeRoundtable(sessionId: String, roundtableId: String): ApiResult<ControlResponse> =
        control(sessionId, roundtableId, "resume")

    /** 提前结束圆桌，进入总结。 */
    suspend fun endRoundtable(sessionId: String, roundtableId: String): ApiResult<ControlResponse> =
        control(sessionId, roundtableId, "end")

    /** 发送用户消息；点名的唯一依据是 [mentionedAgentIds]。 */
    suspend fun sendUserMessage(
        sessionId: String,
        roundtableId: String,
        body: String,
        mentionedAgentIds: List<String> = emptyList(),
    ): ApiResult<ControlResponse> = call(
        path = "/api/v1/roundtables/$roundtableId/user-messages",
        method = "POST",
        sessionId = sessionId,
        body = json.encodeToString(UserMessageRequest(body, mentionedAgentIds)),
        decode = { json.decodeFromString<ControlResponse>(it) },
    )

    private suspend fun control(
        sessionId: String,
        roundtableId: String,
        action: String,
    ): ApiResult<ControlResponse> = call(
        path = "/api/v1/roundtables/$roundtableId/$action",
        method = "POST",
        sessionId = sessionId,
        body = "",
        decode = { json.decodeFromString<ControlResponse>(it) },
    )

    /** 读取结论；尚未生成时为 `{"summary": null}`。 */
    suspend fun getSummary(sessionId: String, roundtableId: String): ApiResult<SummaryEnvelope> =
        call(
            path = "/api/v1/roundtables/$roundtableId/summary",
            method = "GET",
            sessionId = sessionId,
            decode = { json.decodeFromString<SummaryEnvelope>(it) },
        )

    /** 提交或重新生成结论；[RoundSummarySubmission.expectedVersion] 必须是当前版本。 */
    suspend fun submitSummary(
        sessionId: String,
        roundtableId: String,
        submission: RoundSummarySubmission,
    ): ApiResult<RoundSummaryResponse> = call(
        path = "/api/v1/roundtables/$roundtableId/summary",
        method = "POST",
        sessionId = sessionId,
        body = json.encodeToString(submission),
        decode = { json.decodeFromString<RoundSummaryResponse>(it) },
    )

    /** 删除圆桌。成功返回 null 值，失败返回错误信封。 */
    suspend fun deleteRoundtable(sessionId: String, roundtableId: String): ApiResult<Unit> {
        val response = try {
            transport.execute(
                HttpRequest(
                    method = "DELETE",
                    url = baseUrl + "/api/v1/roundtables/" + roundtableId,
                    headers = mapOf("X-Guest-Session" to sessionId),
                ),
            )
        } catch (error: Exception) {
            return ApiResult.Failure(ApiErrorCode.Unknown, "网络连接失败，请检查网络后重试。", 0)
        }
        if (response.statusCode in 200..299) return ApiResult.Success(Unit)
        return errorBody(response.body, response.statusCode)
    }

    private suspend inline fun <T> call(
        path: String,
        method: String,
        sessionId: String? = null,
        body: String? = null,
        decode: (String) -> T,
    ): ApiResult<T> {
        val headers = buildMap {
            if (sessionId != null) put("X-Guest-Session", sessionId)
            if (body != null) put("Content-Type", "application/json")
        }
        val response = try {
            transport.execute(
                HttpRequest(method = method, url = baseUrl + path, headers = headers, body = body),
            )
        } catch (error: Exception) {
            return ApiResult.Failure(
                code = ApiErrorCode.Unknown,
                message = "网络连接失败，请检查网络后重试。",
                httpStatus = 0,
            )
        }

        if (response.statusCode !in 200..299) {
            return errorBody(response.body, response.statusCode)
        }

        return try {
            ApiResult.Success(decode(response.body))
        } catch (error: Exception) {
            ApiResult.Failure(
                code = ApiErrorCode.Unknown,
                message = "服务端返回了无法解析的内容。",
                httpStatus = response.statusCode,
            )
        }
    }

    private fun errorBody(body: String, httpStatus: Int): ApiResult.Failure {
        val envelope = try {
            json.decodeFromString<ErrorEnvelope>(body)
        } catch (error: Exception) {
            null
        }
        if (envelope == null) {
            return ApiResult.Failure(
                code = ApiErrorCode.Unknown,
                message = "服务端返回错误（HTTP $httpStatus）。",
                httpStatus = httpStatus,
            )
        }
        return ApiResult.Failure(
            code = ApiErrorCode.fromWire(envelope.error.code),
            message = envelope.error.message,
            httpStatus = httpStatus,
        )
    }
}
