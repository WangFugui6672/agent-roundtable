package com.agentroundtable.core.provider

import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.api.HttpTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** 一次 Provider 连通性检查的结果，可直接展示。 */
sealed interface ProviderCheckOutcome {
    data class Ok(val modelCount: Int?) : ProviderCheckOutcome

    data object InvalidKey : ProviderCheckOutcome

    data class ModelMissing(val model: String) : ProviderCheckOutcome

    data class Unreachable(val reason: String) : ProviderCheckOutcome

    data class Failed(val reason: String) : ProviderCheckOutcome
}

/**
 * 用 OpenAI 兼容的 `GET /models` 判断配置是否可用。
 *
 * 刻意不发起对话补全：检查配置不该消耗额度。
 */
class ProviderProbe(private val transport: HttpTransport) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun check(configuration: ProviderConfiguration, apiKey: String): ProviderCheckOutcome {
        val base = configuration.baseUrl.trim().removeSuffix("/")
        if (base.isEmpty()) return ProviderCheckOutcome.Failed("BaseURL 无法解析。")

        val response = try {
            transport.execute(
                HttpRequest(
                    method = "GET",
                    url = "$base/models",
                    headers = mapOf(
                        "Authorization" to "Bearer $apiKey",
                        "Accept" to "application/json",
                    ),
                ),
            )
        } catch (error: Exception) {
            return ProviderCheckOutcome.Unreachable(error.message ?: "网络请求失败。")
        }

        if (response.statusCode == 401 || response.statusCode == 403) {
            return ProviderCheckOutcome.InvalidKey
        }
        if (response.statusCode !in 200..299) {
            return ProviderCheckOutcome.Failed("服务商返回 HTTP ${response.statusCode}。")
        }

        val modelIds = runCatching {
            json.parseToJsonElement(response.body)
                .jsonObject["data"]
                ?.jsonArray
                ?.mapNotNull { it.jsonObject["id"]?.toString()?.trim('"') }
        }.getOrNull()

        if (modelIds == null) return ProviderCheckOutcome.Ok(modelCount = null)
        if (modelIds.isNotEmpty() && configuration.model !in modelIds) {
            return ProviderCheckOutcome.ModelMissing(configuration.model)
        }
        return ProviderCheckOutcome.Ok(modelCount = modelIds.size)
    }
}
