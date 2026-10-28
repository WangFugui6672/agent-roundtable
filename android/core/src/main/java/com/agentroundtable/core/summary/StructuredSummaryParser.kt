package com.agentroundtable.core.summary

import com.agentroundtable.core.model.SummaryItem
import com.agentroundtable.core.room.Message
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/** 结论解析结果。失败时给出可直接展示的中文原因。 */
sealed interface SummaryParseResult {
    data class Valid(val draft: SummaryDraft) : SummaryParseResult

    data class Invalid(val reason: String) : SummaryParseResult
}

/**
 * 解析模型返回的严格结构化结论。
 *
 * 模型只能给出候选观点的下标，真实消息 ID 由客户端映射；
 * 任何越界、重复或指向无效消息的引用都会被拒绝。
 */
object StructuredSummaryParser {
    const val maxItemsPerSection = 8
    const val maxReferencesPerItem = 3
    const val maxTextCharacters = 400

    private val json = Json { ignoreUnknownKeys = true }
    private val sectionKeys = listOf("consensus", "dissent", "recommendations", "unresolved")
    private val sectionKeySet = sectionKeys.toSet()
    private val itemKeySet = setOf("text", "reference_indexes")
    private val allowedMessageTypes = setOf(
        "proposal",
        "support",
        "challenge",
        "supplement",
        "question",
    )

    fun parse(raw: String, transcript: List<Message>): SummaryParseResult {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return SummaryParseResult.Invalid("模型没有返回结论内容。")

        val root = runCatching { json.parseToJsonElement(extractJson(trimmed)) as JsonObject }
            .getOrNull()
            ?: return SummaryParseResult.Invalid("模型返回的结论不是合法 JSON。")

        if (root.keys != sectionKeySet) {
            return SummaryParseResult.Invalid(
                "结论 JSON 必须只包含 consensus、dissent、recommendations、unresolved 四个数组。",
            )
        }

        val rawSections = LinkedHashMap<String, JsonArray>()
        for (key in sectionKeys) {
            val section = root[key] as? JsonArray
                ?: return SummaryParseResult.Invalid("结论分组 $key 必须是数组。")
            if (section.size > maxItemsPerSection) {
                return SummaryParseResult.Invalid("单个结论分组最多 8 项。")
            }
            rawSections[key] = section
        }
        if (rawSections.values.all { it.isEmpty() }) {
            return SummaryParseResult.Invalid("结论没有包含任何可引用观点。")
        }

        val candidates = eligibleMessages(transcript)
        val parsed = LinkedHashMap<String, List<SummaryItem>>()
        for (key in sectionKeys) {
            val items = mutableListOf<SummaryItem>()
            for (element in rawSections.getValue(key)) {
                val item = element as? JsonObject
                    ?: return SummaryParseResult.Invalid("结论项必须是对象。")
                if (item.keys != itemKeySet) {
                    return SummaryParseResult.Invalid(
                        "每个结论项只能包含 text 与 reference_indexes。",
                    )
                }

                val textElement = item["text"] as? JsonPrimitive
                if (textElement == null || !textElement.isString) {
                    return SummaryParseResult.Invalid("结论项正文必须是字符串。")
                }
                val text = textElement.content.trim()
                if (text.isEmpty() || text.length > maxTextCharacters) {
                    return SummaryParseResult.Invalid("结论项正文为空或超过 400 字。")
                }

                val referenceElement = item["reference_indexes"] as? JsonArray
                    ?: return SummaryParseResult.Invalid("reference_indexes 必须是数组。")
                val indexes = referenceElement.map { reference ->
                    (reference as? JsonPrimitive)?.intOrNull
                        ?: return SummaryParseResult.Invalid("reference_indexes 必须是整数编号。")
                }
                if (indexes.isEmpty() || indexes.size > maxReferencesPerItem) {
                    return SummaryParseResult.Invalid("单个结论项必须引用 1 到 3 条观点。")
                }
                if (indexes.toSet().size != indexes.size) {
                    return SummaryParseResult.Invalid("同一结论项不能重复引用同一条观点。")
                }
                if (indexes.any { it !in candidates.indices }) {
                    return SummaryParseResult.Invalid("结论项引用了候选讨论之外的来源。")
                }

                items += SummaryItem(
                    text = text,
                    referenceMessageIds = indexes.map { candidates[it].id },
                )
            }
            parsed[key] = items
        }

        return SummaryParseResult.Valid(
            SummaryDraft(
                degraded = false,
                consensus = parsed.getValue("consensus"),
                dissent = parsed.getValue("dissent"),
                recommendations = parsed.getValue("recommendations"),
                unresolved = parsed.getValue("unresolved"),
            ),
        )
    }

    /**
     * 可以作为结论引用来源的消息：当前圆桌内、未被替代的有效 Agent 观点。
     * 关键观点优先，其余保持原顺序。
     */
    fun eligibleMessages(transcript: List<Message>): List<Message> {
        val eligible = transcript.filter { message ->
            message.author.type == "agent" &&
                message.author.roundtableAgentId != null &&
                message.supersededByMessageId == null &&
                message.messageType in allowedMessageTypes &&
                effectiveText(message).isNotBlank()
        }
        return eligible.filter { it.isKeyPoint } + eligible.filterNot { it.isKeyPoint }
    }

    /** 结论与降级摘要优先复述主张；没有主张时退回正文。 */
    internal fun effectiveText(message: Message): String =
        message.claim?.takeIf { it.isNotBlank() } ?: message.body

    /** 模型有时会用代码块包住 JSON，这里只取最外层对象。 */
    private fun extractJson(text: String): String {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        return if (start >= 0 && end > start) text.substring(start, end + 1) else text
    }
}
