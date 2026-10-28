package com.agentroundtable.core.knowledge

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentIndexerTest {
    private val document = knowledgeDocument("doc-1", "笔记.txt", chunkCount = 2)

    private fun storeWithChunks(): InMemoryRetrievalStore = InMemoryRetrievalStore().apply {
        add(document, listOf("甲", "乙"))
    }

    @Test
    fun `导入的文档块逐块完成向量化并报告可感知的进度`() = runTest {
        val store = storeWithChunks()
        val backend = FakeEmbeddingBackend(
            vectorsByText = mapOf(
                "甲" to floatArrayOf(1f, 0f),
                "乙" to floatArrayOf(0f, 1f),
            ),
        )
        val clockValues = ArrayDeque(listOf(100L, 250L))
        val indexer = DocumentIndexer(
            store = store,
            vectorStore = store,
            backend = backend,
            clock = { clockValues.removeFirst() },
        )
        val progress = mutableListOf<VectorizationProgress>()

        val result = indexer.index(document) { progress += it }

        result as VectorizationResult.Completed
        assertEquals("doc-1", result.documentId)
        assertEquals(2, result.chunkCount)
        assertEquals(150L, result.durationMillis)
        assertEquals(
            listOf(0, 1, 2),
            progress.map { it.completedChunks },
        )
        assertTrue(progress.all { it.totalChunks == 2 })
        assertEquals(listOf("甲", "乙"), backend.calls.flatten())
        assertEquals(
            listOf(floatArrayOf(1f, 0f).toList(), floatArrayOf(0f, 1f).toList()),
            store.vectorsOf("doc-1").sortedBy { it.chunkIndex }.map { it.values.toList() },
        )
    }

    @Test
    fun `重新向量化会替换该文档的旧文档块向量`() = runTest {
        val store = storeWithChunks()
        store.putVectors(
            "doc-1",
            listOf(ChunkVector("doc-1", 0, floatArrayOf(9f, 9f))),
        )
        val backend = FakeEmbeddingBackend(
            vectorsByText = mapOf(
                "甲" to floatArrayOf(1f, 0f),
                "乙" to floatArrayOf(0f, 1f),
            ),
        )
        val indexer = DocumentIndexer(store, store, backend)

        val result = indexer.index(document)

        assertTrue(result is VectorizationResult.Completed)
        assertEquals(1, store.replaceVectorCalls)
        assertEquals(2, store.vectorsOf("doc-1").size)
    }

    @Test
    fun `向量化失败返回失败结果且保留旧向量`() = runTest {
        val store = storeWithChunks()
        val oldVectors = listOf(
            ChunkVector("doc-1", 0, floatArrayOf(9f, 9f)),
            ChunkVector("doc-1", 1, floatArrayOf(8f, 8f)),
        )
        store.putVectors("doc-1", oldVectors)
        val backend = FakeEmbeddingBackend(
            vectorsByText = mapOf("甲" to floatArrayOf(1f, 0f)),
        ).apply {
            failure = IllegalStateException("模型初始化失败")
        }
        val indexer = DocumentIndexer(store, store, backend)

        val result = indexer.index(document)

        result as VectorizationResult.Failed
        assertEquals("模型初始化失败", result.message)
        assertEquals(0, store.replaceVectorCalls)
        assertEquals(oldVectors, store.vectorsOf("doc-1"))
    }

    @Test
    fun `已完整向量化的文档不再出现在待处理列表`() = runTest {
        val store = InMemoryRetrievalStore().apply {
            add(knowledgeDocument("missing", "未向量化.txt", 1), listOf("甲"))
            add(knowledgeDocument("partial", "部分向量化.txt", 2), listOf("甲", "乙"))
            add(knowledgeDocument("done", "已完成.txt", 1), listOf("丙"))
            add(knowledgeDocument("empty", "空文档.txt", 0), emptyList())
            putVectors("partial", listOf(ChunkVector("partial", 0, floatArrayOf(1f))))
            putVectors("done", listOf(ChunkVector("done", 0, floatArrayOf(1f))))
        }
        val indexer = DocumentIndexer(store, store, FakeEmbeddingBackend())

        val pending = indexer.pendingDocuments().map { it.id }

        assertEquals(listOf("missing", "partial"), pending)
    }
}
