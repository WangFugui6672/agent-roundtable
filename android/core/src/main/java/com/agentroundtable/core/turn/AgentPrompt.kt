package com.agentroundtable.core.turn

/** 发给模型的一条消息。 */
data class ChatMessage(val role: String, val content: String) {
    companion object {
        fun system(content: String) = ChatMessage("system", content)

        fun user(content: String) = ChatMessage("user", content)
    }
}

/** 一位参与者在某个圆桌中的上下文，用于组装 prompt。 */
data class PromptContext(
    val topic: String,
    val agentName: String,
    val tagline: String,
    val expertise: String,
    val goal: String,
    val defaultStance: String,
    val style: String,
    val bannedBehaviors: List<String>,
    val maxReplyChars: Int,
    val roundNumber: Int,
)

/**
 * 讨论记录中的一条发言。
 *
 * [messageId] 与 [authorAgentId] 用于第二轮引用校验；用户消息的 [authorAgentId] 为 null。
 */
data class TranscriptLine(
    val authorName: String,
    val body: String,
    val messageId: String = "",
    val authorAgentId: String? = null,
)

/**
 * 把一位参与者与讨论记录转成两条消息。
 *
 * 与 iOS 的 `AgentPrompt` 保持同一语义：system 描述身份与规则，user 携带议题与讨论记录。
 */
object AgentPrompt {
    fun messages(
        context: PromptContext,
        transcript: List<TranscriptLine>,
    ): List<ChatMessage> = listOf(
        ChatMessage.system(systemPrompt(context)),
        ChatMessage.user(userPrompt(context, transcript)),
    )

    fun systemPrompt(context: PromptContext): String {
        val role = buildString {
            append("你是圆桌讨论中的「").append(context.agentName).append("」，")
            append(context.tagline).append("。\n")
            append("你始终是 AI，不得声称自己是真人、公众人物，也不得冒充任何真实个人。\n")
            append("专长：").append(context.expertise).append('\n')
            append("当前目标：").append(context.goal).append('\n')
            append("默认立场：").append(context.defaultStance).append('\n')
            append("表达风格：").append(context.style).append('\n')
            if (context.bannedBehaviors.isNotEmpty()) {
                append("禁止行为：").append(context.bannedBehaviors.joinToString("、")).append('\n')
            }
            append("讨论议题：").append(context.topic)
        }
        if (context.roundNumber >= 2) {
            return role + "\n\n" + STRUCTURED_RULES
        }
        return role + "\n\n请只输出中文正文，不要输出 JSON、Markdown 或任何解释。" +
            "控制在 " + context.maxReplyChars + " 字以内。"
    }

    fun userPrompt(context: PromptContext, transcript: List<TranscriptLine>): String {
        if (transcript.isEmpty()) {
            return "议题：" + context.topic + "\n\n讨论尚未开始，请给出你的第一个观点。"
        }
        val history = transcript.joinToString("\n") { "${it.authorName}：${it.body}" }
        if (context.roundNumber >= 2) {
            val candidates = transcript
                .filter { it.authorAgentId != null && it.messageId.isNotBlank() }
                .mapIndexed { index, line ->
                    "${index + 1}. author=${line.authorName} agent_id=${line.authorAgentId} " +
                        "message_id=${line.messageId} 主张=${line.body.take(40)}"
                }
                .joinToString("\n")
            return "议题：" + context.topic + "\n\n讨论记录：\n" + history +
                "\n\n可引用的候选观点：\n" + candidates.ifBlank { "（没有可引用的观点）" } +
                "\n\n请引用其中一条，并按要求返回 JSON。"
        }
        return "议题：" + context.topic + "\n\n讨论记录：\n" + history +
            "\n\n请基于以上讨论说出你的观点。"
    }

    private const val STRUCTURED_RULES = """
现在是第二轮引用式互评。请只返回一个 JSON 对象，不要输出 Markdown 或解释。
JSON 必须包含：
- message_type：support、challenge、supplement 或 question。
- claim：一句话主张，不超过 80 字。
- body：中文正文。
- stance：必须与 message_type 相同。
- reference_message_id：引用候选观点中的一条。
- confidence：0 到 1 之间的数字。
不得引用自己、用户消息、pass 或候选列表之外的观点。
如果没有可引用的有效观点，只输出 PASS。
示例：
{"message_type":"challenge","claim":"成本被低估","body":"我质疑这个判断，因为注意力也是成本。","stance":"challenge","reference_message_id":"UUID","confidence":0.7}
"""
}
