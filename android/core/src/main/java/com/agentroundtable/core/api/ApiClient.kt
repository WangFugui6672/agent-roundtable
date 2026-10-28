package com.agentroundtable.core.api

import com.agentroundtable.core.model.AgentProfile
import com.agentroundtable.core.model.GuestSession
import com.agentroundtable.core.model.ProviderMetadata
import com.agentroundtable.core.model.Roundtable
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
