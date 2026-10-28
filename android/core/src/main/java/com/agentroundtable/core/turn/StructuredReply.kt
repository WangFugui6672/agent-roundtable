package com.agentroundtable.core.turn

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 模型在第二轮返回的结构化发言。 */
@Serializable
data class StructuredReply(
    @SerialName("message_type") val messageType: String = "",
    val claim: String = "",
    val body: String = "",
    val stance: String? = null,
    @SerialName("reference_message_id") val referenceMessageId: String? = null,
    @SerialName("challenge_target_agent_id") val challengeTargetAgentId: String? = null,
    val confidence: Double? = null,
)

/** 解析结果。失败时给出可直接展示的原因。 */
sealed interface ReplyParseResult {
    data class Valid(val reply: StructuredReply) : ReplyParseResult

    data class Invalid(val reason: String) : ReplyParseResult

    /** 模型明确表示没有可引用的观点。 */
    data object Pass : ReplyParseResult
}

/**
 * 解析并校验第二轮的结构化输出。
 *
 * 引用只能指向同一圆桌中更早产生、来自其他参与者的有效 Agent 观点；
 * 质疑还必须把被质疑的 Agent 指定为被引用观点的作者。
 */
object StructuredReplyParser {
    private val json = Json { ignoreUnknownKeys = true }

    private val allowedTypes = setOf("support", "challenge", "supplement", "question")

    fun parse(
        text: String,
        candidates: List<TranscriptLine>,
        currentAgentId: String,
    ): ReplyParseResult {
        val trimmed = text.trim()
        if (MessageComposer.isPass(trimmed)) return ReplyParseResult.Pass

        val reply = runCatching { json.decodeFromString<StructuredReply>(extractJson(trimmed)) }
            .getOrElse { return ReplyParseResult.Invalid("模型没有返回合法的 JSON。") }

        if (reply.messageType !in allowedTypes) {
            return ReplyParseResult.Invalid("第二轮发言类型必须是 support、challenge、supplement 或 question。")
        }
        if (reply.claim.isBlank()) return ReplyParseResult.Invalid("第二轮发言缺少主张。")
        if (reply.body.isBlank()) return ReplyParseResult.Invalid("第二轮发言缺少正文。")
        if (!reply.stance.isNullOrBlank() && reply.stance != reply.messageType) {
            return ReplyParseResult.Invalid("立场与发言类型不一致。")
        }

        val referenceId = reply.referenceMessageId?.takeIf { it.isNotBlank() }
            ?: return ReplyParseResult.Invalid("第二轮发言必须引用一条已有观点。")

        val referenced = candidates.firstOrNull { it.messageId == referenceId }
            ?: return ReplyParseResult.Invalid("引用了不存在的观点。")

        if (referenced.authorAgentId == null) {
            return ReplyParseResult.Invalid("不能引用用户消息。")
        }
        if (referenced.authorAgentId == currentAgentId) {
            return ReplyParseResult.Invalid("不能引用自己的观点。")
        }

        if (reply.messageType == "challenge") {
            val target = reply.challengeTargetAgentId?.takeIf { it.isNotBlank() }
                ?: return ReplyParseResult.Invalid("质疑必须指定被质疑的 Agent。")
            if (target != referenced.authorAgentId) {
                return ReplyParseResult.Invalid("被质疑的 Agent 必须是被引用观点的作者。")
            }
        }

        return ReplyParseResult.Valid(reply)
    }

    /** 模型有时会用代码块包住 JSON，这里只取最外层对象。 */
    private fun extractJson(text: String): String {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        return if (start >= 0 && end > start) text.substring(start, end + 1) else text
    }
}
