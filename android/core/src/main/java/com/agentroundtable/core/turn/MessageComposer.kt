package com.agentroundtable.core.turn

/** 提交给服务端的一条结构化发言。 */
data class MessageSubmission(
    val turnId: String,
    val roundtableAgentId: String,
    val messageType: String,
    val claim: String,
    val body: String,
    val stance: String?,
    val references: List<String> = emptyList(),
    val challengeTargetAgentId: String? = null,
    val confidence: Double = DEFAULT_CONFIDENCE,
) {
    companion object {
        const val DEFAULT_CONFIDENCE = 0.6
        const val CLAIM_LIMIT = 80
    }
}

/**
 * 把模型输出的纯文本转成结构化发言。
 *
 * 第一轮的立场由 Agent 的固定角色决定，与 iOS 的 `MessageComposer` 一致；
 * 正文按 Agent 的最大回复长度截断，主张取第一句。
 */
object MessageComposer {
    fun isPass(text: String): Boolean = text.trim().uppercase() == "PASS"

    fun compose(
        turnId: String,
        roundtableAgentId: String,
        agentKey: String,
        text: String,
        maxReplyChars: Int,
    ): MessageSubmission {
        val trimmed = text.trim()
        val (messageType, stance) = mapping(agentKey)
        return MessageSubmission(
            turnId = turnId,
            roundtableAgentId = roundtableAgentId,
            messageType = messageType,
            claim = claim(trimmed),
            body = trimmed.take(maxReplyChars),
            stance = stance,
        )
    }

    fun mapping(agentKey: String): Pair<String, String?> = when (agentKey) {
        "advocate" -> "proposal" to null
        "skeptic" -> "challenge" to "challenge"
        "experience" -> "supplement" to "supplement"
        else -> "supplement" to null
    }

    fun claim(text: String): String {
        val terminators = setOf('。', '！', '？', '!', '?', '\n')
        val firstSentence = text.split(*terminators.toCharArray())
            .firstOrNull { it.isNotBlank() }
            ?.trim()
            .orEmpty()
        val source = firstSentence.ifEmpty { text.trim() }
        return source.take(MessageSubmission.CLAIM_LIMIT)
    }
}
