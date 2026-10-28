package com.agentroundtable.core.summary

import com.agentroundtable.core.room.Message
import com.agentroundtable.core.turn.ChatMessage

/** 组装结论摘要的 prompt。模型只允许复述候选观点，引用用候选编号表示。 */
object SummaryPrompt {
    fun messages(topic: String, transcript: List<Message>): List<ChatMessage> {
        val candidates = StructuredSummaryParser.eligibleMessages(transcript)
        val candidateText = candidates.mapIndexed { index, message ->
            buildString {
                append('[').append(index).append("] 作者：").append(message.author.name).append('\n')
                append("主张：").append(message.claim.orEmpty()).append('\n')
                append("正文：").append(message.body)
            }
        }.joinToString("\n\n")

        return listOf(
            ChatMessage.system(
                """
                你是圆桌主持人。请只输出一个 JSON 对象，不要 Markdown 或解释。
                输出必须恰好包含 consensus、dissent、recommendations、unresolved 四个数组。
                每个数组最多 8 项；每项必须包含：
                - text：只复述引用观点能够支持的内容，1-400 字。
                - reference_indexes：1-3 个候选观点编号。
                不得引入候选观点之外的事实、数字、人物或建议。
                没有依据时输出空数组。分歧不能包装成共识。
                """.trimIndent(),
            ),
            ChatMessage.user(
                """
                议题：$topic

                可引用观点：
                ${candidateText.ifBlank { "（没有可引用的有效观点）" }}
                """.trimIndent(),
            ),
        )
    }
}
