package com.agentroundtable.core.knowledge

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KnowledgeSearchTest {
    private val budgetText = "讨论预算由轮数、消息数和时长决定。"
    private val weatherText = "今天天气晴朗，适合出门。"
    private val retrievalText = "资料库检索返回来源文档中的文档块。"

    private fun store(): InMemoryRetrievalStore = InMemoryRetrievalStore().apply {
        add(knowledgeDocument("doc-budget", "预算方案", 2), listOf(budgetText, weatherText))
        add(knowledgeDocument("doc-rag", "产品笔记", 1), listOf(retrievalText))
        putVectors(
            "doc-budget",
            listOf(
                ChunkVector("doc-budget", 0, floatArrayOf(1f, 0f, 0f)),
                ChunkVector("doc-budget", 1, floatArrayOf(0f, 1f, 0f)),
            ),
        )
        putVectors(
            "doc-rag",
            listOf(ChunkVector("doc-rag", 0, floatArrayOf(0f, 0f, 1f))),
        )
    }

    @Test
    fun `查询通过假嵌入后端命中相关文档块并返回来源文档名称`() = runTest {
        val backend = FakeEmbeddingBackend(
            vectorsByText = mapOf(
                "讨论预算是多少？" to floatArrayOf(1f, 0f, 0f),
                budgetText to floatArrayOf(1f, 0f, 0f),
                weatherText to floatArrayOf(0f, 1f, 0f),
                retrievalText to floatArrayOf(0f, 0f, 1f),
            ),
        )
        val search = KnowledgeSearch(store(), store(), backend)

        val hits = search.search("讨论预算是多少？")

        assertEquals(1, hits.size)
        assertEquals("预算方案", hits.single().documentName)
        assertEquals(budgetText, hits.single().text)
        assertEquals(1.0f, hits.single().similarity, 0.001f)
        assertEquals(listOf(listOf("讨论预算是多少？")), backend.calls)
    }

    @Test
    fun `无关查询返回空检索结果`() = runTest {
        val backend = FakeEmbeddingBackend(
            vectorsByText = mapOf(
                "帮我写一首诗" to floatArrayOf(0.2f, -0.9f, 0f),
                budgetText to floatArrayOf(1f, 0f, 0f),
                weatherText to floatArrayOf(0f, 1f, 0f),
                retrievalText to floatArrayOf(0f, 0f, 1f),
            ),
        )
        val search = KnowledgeSearch(store(), store(), backend)

        assertTrue(search.search("帮我写一首诗").isEmpty())
    }

    @Test
    fun `空资料库返回空检索结果而不是错误且不调用嵌入后端`() = runTest {
        val emptyStore = InMemoryRetrievalStore()
        val backend = FakeEmbeddingBackend()
        val search = KnowledgeSearch(emptyStore, emptyStore, backend)

        assertTrue(search.search("任意查询").isEmpty())
        assertTrue(backend.calls.isEmpty())
    }

    @Test
    fun `空查询返回空检索结果且不调用嵌入后端`() = runTest {
        val backend = FakeEmbeddingBackend()
        val sharedStore = store()
        val search = KnowledgeSearch(sharedStore, sharedStore, backend)

        assertTrue(search.search("   ").isEmpty())
        assertTrue(backend.calls.isEmpty())
    }

    @Test
    fun `嵌入后端不可用时降级为空检索结果`() = runTest {
        val backend = FakeEmbeddingBackend().apply {
            failure = IllegalStateException("model missing")
        }
        val sharedStore = store()
        val search = KnowledgeSearch(sharedStore, sharedStore, backend)

        assertTrue(search.search("讨论预算是多少？").isEmpty())
    }
}
