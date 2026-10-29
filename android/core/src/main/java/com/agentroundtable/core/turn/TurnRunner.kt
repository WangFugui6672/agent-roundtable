package com.agentroundtable.core.turn

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.knowledge.RetrievalHit
import com.agentroundtable.core.provider.ProviderConfiguration
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull

/** 一次 Turn 执行的结果。 */
sealed interface TurnRunResult {
    /** 当前没有可发言的参与者。 */
    data object NoTurn : TurnRunResult

    /**
     * 已提交一条发言。
     *
     * [turnId] 用于把本地检索结果关联到服务端随后产生的消息；
     * [references] 是本次发言实际注入 prompt 的参考资料。
     */
    data class Spoke(
        val text: String,
        val turnId: String = "",
        val references: List<RetrievalHit> = emptyList(),
    ) : TurnRunResult

    /** Agent 明确选择沉默。 */
    data object Passed : TurnRunResult

    /** 执行失败，已用 `agent.failed` 关闭该 Turn。 */
    data class Failed(val message: String, val retryable: Boolean) : TurnRunResult
}

/**
 * 执行一次完整的 Agent 发言：取 Turn → 组装 prompt → 直连 Provider 流式生成 → 提交或关闭 Turn。
 *
 * 密钥只用于直连 Provider 的请求；提交给服务端的请求体不含任何密钥字段。
 *
 * [retrieval] 是可选的本机资料库检索接缝。不传时不发起任何检索，prompt 与接入资料库
 * 之前完全一致；传入但检索为空、超时或失败时同样降级为无检索，不阻塞发言。
 */
class TurnRunner(
    private val api: ApiClient,
    private val chat: ProviderChatClient,
    private val retrieval: Retrieval? = null,
) {
    suspend fun runOnce(
        sessionId: String,
        roundtableId: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        transcript: List<TranscriptLine>,
        contextFor: (agentId: String) -> PromptContext?,
        onDelta: (String) -> Unit,
    ): TurnRunResult {
        val next = when (val result = api.nextTurn(sessionId, roundtableId)) {
            is ApiResult.Failure -> return TurnRunResult.Failed(result.message, retryable = false)
            is ApiResult.Success -> result.value
        }
        val turn = next.turn ?: return TurnRunResult.NoTurn

        val context = contextFor(turn.roundtableAgentId)
            ?: return failTurn(
                sessionId, roundtableId, turn,
                code = "agent_context_missing",
                message = "缺少该参与者的上下文，无法生成发言。",
                retryable = false,
            )

        // 轮次以服务端签发 Turn 时给出的为准，界面上的 currentRound 可能还没更新。
        val turnContext = context.copy(roundNumber = next.round)

        // 检索在发起 Provider 请求前完成；失败、超时或空资料库都降级为空列表。
        val references = retrieveReferences(turnContext, transcript)

        val builder = StringBuilder()
        var streamError: String? = null
        chat.stream(
            configuration = configuration,
            apiKey = apiKey,
            messages = AgentPrompt.messages(turnContext, transcript, references),
        ).collect { event ->
            when (event) {
                is ChatStreamEvent.Delta -> {
                    builder.append(event.text)
                    onDelta(event.text)
                }
                is ChatStreamEvent.Failed -> streamError = event.message
                ChatStreamEvent.Completed -> Unit
            }
        }

        streamError?.let { reason ->
            return failTurn(
                sessionId, roundtableId, turn,
                code = "provider_error",
                message = reason,
                retryable = true,
                partial = builder.toString().ifBlank { null },
            )
        }

        val text = builder.toString().trim()
        if (text.isEmpty()) {
            return failTurn(
                sessionId, roundtableId, turn,
                code = "provider_empty_reply",
                message = "模型返回了空回复。",
                retryable = true,
            )
        }
        // 第二轮起必须返回结构化 JSON，并引用一条更早的其他参与者观点。
        if (turnContext.roundNumber >= 2) {
            when (val parsed = StructuredReplyParser.parse(text, transcript, turn.roundtableAgentId)) {
                ReplyParseResult.Pass -> return passTurn(sessionId, roundtableId, turn)
                is ReplyParseResult.Invalid -> return failTurn(
                    sessionId, roundtableId, turn,
                    code = "provider_invalid_response",
                    message = parsed.reason,
                    retryable = true,
                )
                is ReplyParseResult.Valid -> {
                    val reply = parsed.reply
                    val submission = MessageSubmission(
                        turnId = turn.turnId,
                        roundtableAgentId = turn.roundtableAgentId,
                        messageType = reply.messageType,
                        claim = reply.claim.take(MessageSubmission.CLAIM_LIMIT),
                        body = reply.body.take(turnContext.maxReplyChars),
                        stance = reply.stance ?: reply.messageType,
                        references = listOfNotNull(reply.referenceMessageId),
                        challengeTargetAgentId = reply.challengeTargetAgentId,
                        confidence = reply.confidence ?: MessageSubmission.DEFAULT_CONFIDENCE,
                    )
                    return when (val result = api.submitMessage(sessionId, roundtableId, submission)) {
                        is ApiResult.Success -> TurnRunResult.Spoke(text, turn.turnId, references)
                        is ApiResult.Failure -> failTurn(
                            sessionId, roundtableId, turn,
                            code = "submit_failed",
                            message = result.message,
                            retryable = true,
                        )
                    }
                }
            }
        }

        if (MessageComposer.isPass(text)) {
            return passTurn(sessionId, roundtableId, turn)
        }

        val submission = MessageComposer.compose(
            turnId = turn.turnId,
            roundtableAgentId = turn.roundtableAgentId,
            agentKey = turn.agentKey,
            text = text,
            maxReplyChars = turnContext.maxReplyChars,
        )
        return when (val result = api.submitMessage(sessionId, roundtableId, submission)) {
            is ApiResult.Success -> TurnRunResult.Spoke(text, turn.turnId, references)
            is ApiResult.Failure -> {
                failTurn(
                    sessionId, roundtableId, turn,
                    code = "submit_failed",
                    message = result.message,
                    retryable = true,
                )
            }
        }
    }

    /**
     * 本次发言的检索查询：优先使用最近一条用户消息，让用户插话能影响后续发言；
     * 没有用户消息时退回议题。
     */
    internal fun retrievalQuery(
        context: PromptContext,
        transcript: List<TranscriptLine>,
    ): String =
        transcript.lastOrNull { it.authorAgentId == null }?.body?.takeIf { it.isNotBlank() }
            ?: context.topic

    /**
     * 检索失败、超时或未注入时统一返回空列表，调用方无需为「无检索」写分支。
     */
    private suspend fun retrieveReferences(
        context: PromptContext,
        transcript: List<TranscriptLine>,
    ): List<RetrievalHit> {
        val retrieval = retrieval ?: return emptyList()
        val query = retrievalQuery(context, transcript)
        if (query.isBlank()) return emptyList()

        return try {
            withTimeoutOrNull(RETRIEVAL_TIMEOUT_MS) { retrieval.retrieve(query) }
                ?.let(AgentPrompt::selectReferences)
                .orEmpty()
        } catch (error: CancellationException) {
            // 圆桌整体取消时不应被降级逻辑吞掉。
            throw error
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun passTurn(
        sessionId: String,
        roundtableId: String,
        turn: ScheduledTurn,
    ): TurnRunResult =
        when (val result = api.passTurn(sessionId, roundtableId, turn.turnId, turn.roundtableAgentId)) {
            is ApiResult.Success -> TurnRunResult.Passed
            is ApiResult.Failure -> TurnRunResult.Failed(result.message, retryable = true)
        }

    private suspend fun failTurn(
        sessionId: String,
        roundtableId: String,
        turn: ScheduledTurn,
        code: String,
        message: String,
        retryable: Boolean,
        partial: String? = null,
    ): TurnRunResult {
        api.failTurn(
            sessionId = sessionId,
            roundtableId = roundtableId,
            turnId = turn.turnId,
            roundtableAgentId = turn.roundtableAgentId,
            failureCode = code,
            message = message,
            retryable = retryable,
            partial = partial,
        )
        return TurnRunResult.Failed(message, retryable)
    }

    private companion object {
        /**
         * 检索超时上限。端侧嵌入首次加载约数百毫秒，留出余量后仍能在
         * 明显拖慢发言前降级为无检索。
         */
        const val RETRIEVAL_TIMEOUT_MS = 1_500L
    }
}
