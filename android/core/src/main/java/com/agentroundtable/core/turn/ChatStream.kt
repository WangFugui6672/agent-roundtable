package com.agentroundtable.core.turn

import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.provider.ProviderConfiguration
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** 逐行读取 Provider 的 SSE 响应。真实实现走 OkHttp，测试用固定行序列。 */
fun interface StreamSource {
    fun open(request: HttpRequest): Flow<String>
}

/** 流式生成过程中对外暴露的事件。 */
sealed interface ChatStreamEvent {
    data class Delta(val text: String) : ChatStreamEvent

    data object Completed : ChatStreamEvent

    data class Failed(val message: String) : ChatStreamEvent
}

/**
 * 直连 OpenAI 兼容服务商的对话补全。
 *
 * 密钥只出现在本请求的 Authorization 头里，不进入任何持久化或日志。
 */
class ProviderChatClient(private val source: StreamSource) {
    private val json = Json { ignoreUnknownKeys = true }

    fun stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: List<ChatMessage>,
        maxTokens: Int = DEFAULT_MAX_TOKENS,
    ): Flow<ChatStreamEvent> = flow {
        val body = buildBody(configuration.model, messages, maxTokens)
        val request = HttpRequest(
            method = "POST",
            url = configuration.baseUrl.trim().removeSuffix("/") + "/chat/completions",
            headers = mapOf(
                "Authorization" to "Bearer $apiKey",
                "Content-Type" to "application/json",
                "Accept" to "text/event-stream",
            ),
            body = body,
        )

        try {
            source.open(request).collect { raw ->
                val line = raw.trim()
                if (line.isEmpty() || !line.startsWith(DATA_PREFIX)) return@collect
                val payload = line.removePrefix(DATA_PREFIX).trim()
                if (payload == DONE) {
                    emit(ChatStreamEvent.Completed)
                    return@collect
                }
                val text = extractDelta(payload) ?: return@collect
                if (text.isNotEmpty()) emit(ChatStreamEvent.Delta(text))
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            // 网络中断、DNS 失败、TLS 错误都在这里收敛为可展示的失败，不让异常冒到 UI 层。
            emit(ChatStreamEvent.Failed(error.message ?: "网络请求失败。"))
        }
    }

    private fun extractDelta(payload: String): String? = runCatching {
        val root = json.parseToJsonElement(payload).jsonObject
        root["choices"]?.jsonArray
            ?.firstOrNull()
            ?.jsonObject
            ?.get("delta")
            ?.jsonObject
            ?.get("content")
            ?.jsonPrimitive
            ?.content
    }.getOrNull()

    private fun buildBody(model: String, messages: List<ChatMessage>, maxTokens: Int): String {
        val messageJson = messages.joinToString(",") { message ->
            """{"role":"${message.role}","content":${JsonPrimitive(message.content)}}"""
        }
        return """{"model":"$model","stream":true,"max_tokens":$maxTokens,"messages":[$messageJson]}"""
    }

    private companion object {
        const val DATA_PREFIX = "data:"
        const val DONE = "[DONE]"
        const val DEFAULT_MAX_TOKENS = 400
    }
}
