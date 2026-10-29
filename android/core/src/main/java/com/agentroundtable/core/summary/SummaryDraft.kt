package com.agentroundtable.core.summary

import com.agentroundtable.core.model.RoundSummarySubmission
import com.agentroundtable.core.model.SummaryItem

/** 生成后、提交前的结论草稿。[degraded] 为 true 表示规则化降级结果。 */
data class SummaryDraft(
    val degraded: Boolean,
    val consensus: List<SummaryItem>,
    val dissent: List<SummaryItem>,
    val recommendations: List<SummaryItem>,
    val unresolved: List<SummaryItem>,
) {
    val hasContent: Boolean
        get() = consensus.isNotEmpty() ||
            dissent.isNotEmpty() ||
            recommendations.isNotEmpty() ||
            unresolved.isNotEmpty()

    fun submission(expectedVersion: Int) = RoundSummarySubmission(
        expectedVersion = expectedVersion,
        degraded = degraded,
        consensus = consensus,
        dissent = dissent,
        recommendations = recommendations,
        unresolved = unresolved,
    )
}
