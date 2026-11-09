package com.agentroundtable.core.summary

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiErrorCode
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.room.Message
import com.agentroundtable.core.turn.ChatMessage
import com.agentroundtable.core.turn.ChatStreamEvent
import com.agentroundtable.core.turn.ProviderChatClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** 结论生成与提交的最终结果。 */
sealed interface SummaryRunResult {
    /** 服务端已保存（或幂等确认）结论。 */
    data class Saved(
        val response: RoundSummaryResponse,
        val draft: SummaryDraft,
    ) : SummaryRunResult

    /** 版本过期：明确提示用户，不静默覆盖。 */
    data class Conflict(val message: String) : SummaryRunResult

    /** 生成或保存失败。模型摘要失败本身不会走到这里，而是降级为规则化结论。 */
    data class Failed(val message: String) : SummaryRunResult
}

/**
 * 生成并提交结论。
 *
 * 模型摘要严格校验，最多重试一次；仍失败或没有可用 Provider 时使用规则化降级，
 * 生成的草稿只创建一次，后续网络重试提交完全相同的请求体，由服务端保证幂等。
 */
class RoundSummaryGenerator(
    private val api: ApiClient,
    private val chat: ProviderChatClient,
    private val submitRetries: Int = 2,
    private val retryDelayMs: Long = 250,
) {
    suspend fun generateAndSubmit(
        sessionId: String,
        roundtableId: String,
        topic: String,
        transcript: List<Message>,
        expectedVersion: Int,
        configuration: ProviderConfiguration?,
        apiKey: String?,
    ): SummaryRunResult {
        val draft = generateDraft(topic, transcript, configuration, apiKey)
        return submit(sessionId, roundtableId, draft, expectedVersion)
    }

    /** 只生成草稿，不访问服务端；测试与预览可以直接使用。 */
    suspend fun generateDraft(
        topic: String,
        transcript: List<Message>,
        configuration: ProviderConfiguration?,
        apiKey: String?,
    ): SummaryDraft {
        if (configuration == null || apiKey.isNullOrBlank()) {
            return RuleBasedSummary.make(transcript)
        }
        if (StructuredSummaryParser.eligibleMessages(transcript).isEmpty()) {
            return RuleBasedSummary.make(transcript)
        }

        val basePrompt = SummaryPrompt.messages(topic, transcript)
        repeat(MAX_MODEL_ATTEMPTS) { attempt ->
            val messages = if (attempt == 0) {
                basePrompt
            } else {
                basePrompt + ChatMessage.user(RETRY_INSTRUCTION)
            }
            val text = collectReply(configuration, apiKey, messages, summaryMaxTokens(attempt))
                ?: return@repeat
            when (val parsed = StructuredSummaryParser.parse(text, transcript)) {
                is SummaryParseResult.Valid -> return parsed.draft
                is SummaryParseResult.Invalid -> Unit
            }
        }
        return RuleBasedSummary.make(transcript)
    }

    suspend fun submit(
        sessionId: String,
        roundtableId: String,
        draft: SummaryDraft,
        expectedVersion: Int,
    ): SummaryRunResult {
        // 请求体只构造一次：同一轮生成中的网络重试必须逐字节相同。
        val submission = draft.submission(expectedVersion)
        var lastFailure: ApiResult.Failure? = null

        for (attempt in 0..submitRetries) {
            when (val result = api.submitSummary(sessionId, roundtableId, submission)) {
                is ApiResult.Success -> {
                    return SummaryRunResult.Saved(result.value, draft)
                }

                is ApiResult.Failure -> {
                    if (result.code == ApiErrorCode.SummaryVersionConflict) {
                        return SummaryRunResult.Conflict(CONFLICT_MESSAGE)
                    }
                    lastFailure = result
                    if (!isRetryable(result) || attempt == submitRetries) {
                        return SummaryRunResult.Failed("结论保存失败：${result.message}")
                    }
                    delay(retryDelayMs)
                }
            }
        }
        return SummaryRunResult.Failed(
            "结论保存失败：${lastFailure?.message ?: "网络连接失败，请检查网络后重试。"}",
        )
    }

    /**
     * 思考型模型会先产出大量 reasoning token，再输出 JSON。
     * 预算太小时 JSON 会在中途被截断（finish_reason=length），表现为「模型返回的结论不是合法 JSON」。
     * 重试时再放宽一档，避免同一预算下重复截断。
     */
    internal fun summaryMaxTokens(attempt: Int): Int =
        if (attempt == 0) SUMMARY_MAX_TOKENS else SUMMARY_RETRY_MAX_TOKENS

    private suspend fun collectReply(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: List<ChatMessage>,
        maxTokens: Int,
    ): String? {
        val builder = StringBuilder()
        var failure: String? = null
        try {
            chat.stream(
                configuration = configuration,
                apiKey = apiKey,
                messages = messages,
                maxTokens = maxTokens,
            ).collect { event ->
                when (event) {
                    is ChatStreamEvent.Delta -> builder.append(event.text)
                    is ChatStreamEvent.Failed -> failure = event.message
                    is ChatStreamEvent.Completed -> Unit
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return null
        }
        if (failure != null) return null
        return builder.toString().trim().ifBlank { null }
    }

    /** 网络中断与 5xx 可以安全重试；4xx 是确定性拒绝，不重试。 */
    private fun isRetryable(failure: ApiResult.Failure): Boolean =
        failure.httpStatus == 0 || failure.httpStatus >= 500

    private companion object {
        const val MAX_MODEL_ATTEMPTS = 2
        // 思考型模型的 reasoning 长度波动极大（实测同一提示词 0–12k 字符），
        // 预算需覆盖 reasoning + JSON 正文，否则 finish_reason=length 会把 JSON 截断。
        const val SUMMARY_MAX_TOKENS = 16_000
        const val SUMMARY_RETRY_MAX_TOKENS = 20_000
        const val CONFLICT_MESSAGE = "结论已在其他生成中更新（版本冲突），请刷新后基于最新版本重新生成。"
        const val RETRY_INSTRUCTION =
            "上一次输出未通过严格 schema 校验。请只返回包含 consensus、dissent、" +
                "recommendations、unresolved 的 JSON，reference_indexes 必须来自给定候选观点。"
    }
}
