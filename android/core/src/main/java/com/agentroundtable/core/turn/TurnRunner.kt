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
        onReset: () -> Unit = {},
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

        val messages = AgentPrompt.messages(turnContext, transcript, references)
        var collected = collectReply(
            configuration = configuration,
            apiKey = apiKey,
            messages = messages,
            maxTokens = turnMaxTokens(turnContext.roundNumber),
            onDelta = onDelta,
        )

        // 结构化输出偶尔会缺字段或返回空正文；用一次更明确的修复提示重试，
        // 避免把一次格式抖动直接变成用户可见的失败。
        if (turnContext.roundNumber >= 2 &&
            collected.error == null &&
            needsStructuredRepair(collected.text, transcript, turn.roundtableAgentId)
        ) {
            onReset()
            collected = collectReply(
                configuration = configuration,
                apiKey = apiKey,
                messages = messages + ChatMessage.user(REPAIR_PROMPT),
                maxTokens = REPAIR_MAX_TOKENS,
                onDelta = onDelta,
            )
        }

        collected.error?.let { reason ->
            return failTurn(
                sessionId, roundtableId, turn,
                code = "provider_error",
                message = reason,
                retryable = true,
                partial = collected.text.ifBlank { null },
            )
        }

        val text = collected.text
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

    private suspend fun collectReply(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: List<ChatMessage>,
        maxTokens: Int,
        onDelta: (String) -> Unit,
    ): CollectedReply {
        val builder = StringBuilder()
        var error: String? = null
        chat.stream(
            configuration = configuration,
            apiKey = apiKey,
            messages = messages,
            maxTokens = maxTokens,
        ).collect { event ->
            when (event) {
                is ChatStreamEvent.Delta -> {
                    builder.append(event.text)
                    onDelta(event.text)
                }
                is ChatStreamEvent.Failed -> error = event.message
                ChatStreamEvent.Completed -> Unit
            }
        }
        return CollectedReply(builder.toString().trim(), error)
    }

    private fun needsStructuredRepair(
        text: String,
        transcript: List<TranscriptLine>,
        agentId: String,
    ): Boolean {
        if (text.isEmpty()) return true
        return StructuredReplyParser.parse(text, transcript, agentId) is ReplyParseResult.Invalid
    }

    private data class CollectedReply(val text: String, val error: String?)

    /**
     * 单次发言的输出预算。
     *
     * 思考型模型会先消耗推理 Token，再输出正文；预算过小时正文可能为空。
     * 第二轮要求结构化 JSON，额外留出引用与字段开销，与 iOS 的
     * `SecondRoundTokenBudget.initial` 保持一致。
     */
    internal fun turnMaxTokens(round: Int): Int =
        if (round >= 2) SECOND_ROUND_MAX_TOKENS else FIRST_ROUND_MAX_TOKENS

    private companion object {
        /**
         * 检索超时上限。端侧嵌入首次加载约数百毫秒，留出余量后仍能在
         * 明显拖慢发言前降级为无检索。
         */
        const val RETRIEVAL_TIMEOUT_MS = 1_500L
        const val FIRST_ROUND_MAX_TOKENS = 600
        const val SECOND_ROUND_MAX_TOKENS = 1_200
        const val REPAIR_MAX_TOKENS = 2_000
        const val REPAIR_PROMPT =
            "上一次输出不是合法的互评 JSON。请严格只返回 system 要求的 JSON 对象，" +
                "必须包含合法 stance、一条候选引用、challenge 时原样填写被质疑者的 " +
                "roundtable_agent_id、confidence。不要输出 Markdown 或解释。"
    }
}
