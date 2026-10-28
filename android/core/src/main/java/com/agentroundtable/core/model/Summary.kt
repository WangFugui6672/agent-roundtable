package com.agentroundtable.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 结论项：一段可展示的正文，以及它依据的真实 Agent 观点。 */
@Serializable
data class SummaryItem(
    val text: String,
    @SerialName("reference_message_ids") val referenceMessageIds: List<String>,
)

/** 服务端保存的结构化结论。版本仅在重新生成时递增。 */
@Serializable
data class RoundSummary(
    val id: String = "",
    val version: Int = 0,
    val degraded: Boolean = false,
    val consensus: List<SummaryItem> = emptyList(),
    val dissent: List<SummaryItem> = emptyList(),
    val recommendations: List<SummaryItem> = emptyList(),
    val unresolved: List<SummaryItem> = emptyList(),
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
) {
    val hasContent: Boolean
        get() = consensus.isNotEmpty() ||
            dissent.isNotEmpty() ||
            recommendations.isNotEmpty() ||
            unresolved.isNotEmpty()
}

/** 提交结论的请求体。重复生成必须携带当前版本。 */
@Serializable
data class RoundSummarySubmission(
    @SerialName("expected_version") val expectedVersion: Int,
    val degraded: Boolean,
    val consensus: List<SummaryItem>,
    val dissent: List<SummaryItem>,
    val recommendations: List<SummaryItem>,
    val unresolved: List<SummaryItem>,
)

/** `GET /summary` 的响应。尚未生成结论时 [summary] 为 null。 */
@Serializable
data class SummaryEnvelope(val summary: RoundSummary? = null)
