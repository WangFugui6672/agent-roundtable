package com.agentroundtable.core.summary

import com.agentroundtable.core.model.SummaryItem
import com.agentroundtable.core.room.Message

/**
 * 模型摘要不可用时的规则化降级。
 *
 * 只复述真实 Agent 观点的主张或正文，并引用该观点本身；不合并、不推断、不引入新事实。
 * 生成结果始终标记 `degraded = true`，由界面明确提示这不是模型生成的结论。
 */
object RuleBasedSummary {
    fun make(transcript: List<Message>): SummaryDraft {
        val candidates = StructuredSummaryParser.eligibleMessages(transcript)

        fun items(types: Set<String>): List<SummaryItem> = candidates
            .filter { it.messageType in types }
            .take(StructuredSummaryParser.maxItemsPerSection)
            .mapNotNull { message ->
                val text = StructuredSummaryParser.effectiveText(message).trim()
                if (text.isEmpty()) return@mapNotNull null
                SummaryItem(
                    text = text.take(StructuredSummaryParser.maxTextCharacters),
                    referenceMessageIds = listOf(message.id),
                )
            }

        return SummaryDraft(
            degraded = true,
            consensus = items(setOf("support")),
            dissent = items(setOf("challenge")),
            recommendations = items(setOf("proposal", "supplement")),
            unresolved = items(setOf("question")),
        )
    }
}
