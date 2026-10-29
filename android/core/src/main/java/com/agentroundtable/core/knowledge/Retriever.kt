package com.agentroundtable.core.knowledge

import kotlin.math.sqrt

/** 带来源文档信息的文档块向量，是 [Retriever] 的输入。 */
data class EmbeddedChunk(
    val documentId: String,
    val documentName: String,
    val chunkIndex: Int,
    val text: String,
    val vector: FloatArray,
)

/** 检索结果：相似度达到阈值的文档块及其相似度分数。 */
data class RetrievalHit(
    val documentId: String,
    val documentName: String,
    val chunkIndex: Int,
    val text: String,
    val similarity: Float,
)

/**
 * 纯检索器。
 *
 * 输入查询向量与文档块向量，输出相似度达到 [MATCH_THRESHOLD] 的检索结果，
 * 按相似度降序最多 [MAX_RESULTS] 条。不依赖 Android 框架、协程或存储。
 *
 * 空资料库、空查询向量、零向量和维度不一致的文档块都不会产生检索结果；
 * 空结果是正常结果，不是错误。
 */
object Retriever {
    /** 相似度阈值：低于该值的文档块不进入 Agent 上下文。 */
    const val MATCH_THRESHOLD = 0.45f

    /** 单次查询最多返回的检索结果数量。 */
    const val MAX_RESULTS = 3

    fun retrieve(query: FloatArray, chunks: List<EmbeddedChunk>): List<RetrievalHit> {
        if (chunks.isEmpty()) return emptyList()

        return chunks.asSequence()
            .mapNotNull { chunk ->
                val similarity = cosineSimilarity(query, chunk.vector) ?: return@mapNotNull null
                if (similarity < MATCH_THRESHOLD) return@mapNotNull null
                RetrievalHit(
                    documentId = chunk.documentId,
                    documentName = chunk.documentName,
                    chunkIndex = chunk.chunkIndex,
                    text = chunk.text,
                    similarity = similarity,
                )
            }
            // 分数相同时用来源文档与块序号兜底，保证结果稳定可测。
            .sortedWith(
                compareByDescending<RetrievalHit> { it.similarity }
                    .thenBy { it.documentId }
                    .thenBy { it.chunkIndex },
            )
            .take(MAX_RESULTS)
            .toList()
    }

    /** 余弦相似度；零向量、空向量或维度不一致时返回 null。 */
    internal fun cosineSimilarity(left: FloatArray, right: FloatArray): Float? {
        if (left.isEmpty() || left.size != right.size) return null

        var dot = 0.0
        var leftNormSquared = 0.0
        var rightNormSquared = 0.0
        for (index in left.indices) {
            val leftValue = left[index]
            val rightValue = right[index]
            dot += leftValue.toDouble() * rightValue.toDouble()
            leftNormSquared += leftValue.toDouble() * leftValue.toDouble()
            rightNormSquared += rightValue.toDouble() * rightValue.toDouble()
        }
        if (leftNormSquared == 0.0 || rightNormSquared == 0.0) return null

        val similarity = dot / (sqrt(leftNormSquared) * sqrt(rightNormSquared))
        if (!similarity.isFinite()) return null
        return similarity.toFloat().coerceIn(-1f, 1f)
    }
}
