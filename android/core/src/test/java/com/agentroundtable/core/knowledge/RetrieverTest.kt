package com.agentroundtable.core.knowledge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RetrieverTest {
    private fun chunk(
        documentId: String,
        chunkIndex: Int,
        vector: FloatArray,
        documentName: String = "文档-$documentId",
    ) = EmbeddedChunk(
        documentId = documentId,
        documentName = documentName,
        chunkIndex = chunkIndex,
        text = "文档块 $documentId-$chunkIndex",
        vector = vector,
    )

    @Test
    fun `相似度阈值是 0_45 且最多返回三条检索结果`() {
        assertEquals(0.45f, Retriever.MATCH_THRESHOLD, 0f)
        assertEquals(3, Retriever.MAX_RESULTS)
    }

    @Test
    fun `查询返回达到相似度阈值的文档块并按相似度降序最多三条检索结果`() {
        val query = floatArrayOf(1f, 0f)
        val chunks = listOf(
            chunk("a", 0, floatArrayOf(1f, 0f)),
            chunk("a", 1, floatArrayOf(0.9f, 0.4358899f)),
            chunk("b", 0, floatArrayOf(0.7f, 0.7141428f)),
            chunk("b", 1, floatArrayOf(0.6f, 0.8f)),
            chunk("c", 0, floatArrayOf(0.2f, 0.9797959f)),
        )

        val hits = Retriever.retrieve(query, chunks)

        assertEquals(3, hits.size)
        assertEquals(listOf("a", "a", "b"), hits.map { it.documentId })
        assertEquals(listOf(0, 1, 0), hits.map { it.chunkIndex })
        assertEquals(1.0f, hits[0].similarity, 0.001f)
        assertEquals(0.9f, hits[1].similarity, 0.001f)
        assertEquals(0.7f, hits[2].similarity, 0.001f)
    }

    @Test
    fun `相似度低于相似度阈值的文档块不构成检索结果`() {
        val query = floatArrayOf(1f, 0f)
        val chunks = listOf(
            chunk("low", 0, floatArrayOf(0.44f, 0.8979977f)),
            chunk("high", 0, floatArrayOf(0.46f, 0.8879428f)),
        )

        val hits = Retriever.retrieve(query, chunks)

        assertEquals(listOf("high"), hits.map { it.documentId })
        assertTrue(hits.single().similarity >= Retriever.MATCH_THRESHOLD)
    }

    @Test
    fun `无关查询返回空检索结果`() {
        val hits = Retriever.retrieve(
            query = floatArrayOf(1f, 0f),
            chunks = listOf(
                chunk("orthogonal", 0, floatArrayOf(0f, 1f)),
                chunk("opposite", 1, floatArrayOf(-1f, 0f)),
            ),
        )

        assertTrue(hits.isEmpty())
    }

    @Test
    fun `空资料库返回空检索结果而不是错误`() {
        assertTrue(Retriever.retrieve(floatArrayOf(1f, 0f), emptyList()).isEmpty())
    }

    @Test
    fun `零向量与维度不一致的文档块向量被忽略`() {
        val hits = Retriever.retrieve(
            query = floatArrayOf(1f, 0f),
            chunks = listOf(
                chunk("zero", 0, floatArrayOf(0f, 0f)),
                chunk("wrong-dimension", 1, floatArrayOf(1f)),
                chunk("not-a-number", 2, floatArrayOf(Float.NaN, 0f)),
                chunk("valid", 3, floatArrayOf(1f, 0f)),
            ),
        )

        assertEquals(listOf("valid"), hits.map { it.documentId })
    }

    @Test
    fun `相似度相同时按来源文档和文档块顺序稳定排序`() {
        val hits = Retriever.retrieve(
            query = floatArrayOf(1f, 0f),
            chunks = listOf(
                chunk("b", 0, floatArrayOf(1f, 0f)),
                chunk("a", 1, floatArrayOf(1f, 0f)),
                chunk("a", 0, floatArrayOf(1f, 0f)),
            ),
        )

        assertEquals(listOf("a-0", "a-1", "b-0"), hits.map { "${it.documentId}-${it.chunkIndex}" })
    }
}
