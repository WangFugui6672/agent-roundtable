package com.agentroundtable.app.data.knowledge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.agentroundtable.core.knowledge.ChunkVector
import com.agentroundtable.core.knowledge.ChunkVectorStore
import com.agentroundtable.core.knowledge.DocumentChunk
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.DocumentIndexer
import com.agentroundtable.core.knowledge.DocumentStore
import com.agentroundtable.core.knowledge.EMBEDDING_DIMENSION
import com.agentroundtable.core.knowledge.KnowledgeDocument
import com.agentroundtable.core.knowledge.KnowledgeSearch
import com.agentroundtable.core.knowledge.VectorizationResult
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 真实模型自检：在设备上加载随包分发的 int8 ONNX 模型，验证 512 维输出、
 * 相关查询命中与文档块向量化耗时。单元测试不依赖这份模型文件。
 */
@RunWith(AndroidJUnit4::class)
class OnnxEmbeddingInstrumentedTest {
    private val budgetText = "讨论预算由轮数、消息数和时长决定。"
    private val weatherText = "今天天气晴朗，适合出门散步。"
    private val retrievalText = "资料库检索返回来源文档中的文档块。"

    @Test
    fun realModelLoadsAndRetrievesRelevantChunk() = runBlocking {
        val assets = InstrumentationRegistry.getInstrumentation().targetContext.assets
        val backend = OnnxEmbeddingBackend(assets)

        val firstVector = backend.embed(listOf(budgetText)).single()
        assertEquals(EMBEDDING_DIMENSION, firstVector.size)
        val modelLoadMillis = backend.modelLoadMillis
        val firstInferenceMillis = backend.lastInferenceMillis

        val store = TestStore().apply {
            add(
                KnowledgeDocument(
                    id = "doc-1",
                    name = "团队约定.txt",
                    format = DocumentFormat.Txt,
                    chunkCount = 3,
                    importedAt = 1L,
                ),
                listOf(budgetText, weatherText, retrievalText),
            )
        }
        val indexer = DocumentIndexer(store = store, vectorStore = store, backend = backend)

        val vectorization = indexer.index(store.document("doc-1"))
        vectorization as VectorizationResult.Completed
        assertEquals(3, vectorization.chunkCount)

        val search = KnowledgeSearch(store = store, vectorStore = store, backend = backend)
        val hits = search.search("讨论预算是多少？")
        assertTrue(hits.isNotEmpty())
        assertEquals(budgetText, hits.first().text)
        assertTrue(hits.first().similarity >= 0.45f)
        assertTrue(hits.size <= 3)

        println(
            "EMBEDDING_METRICS " +
                "modelLoadMs=$modelLoadMillis " +
                "firstInferenceMs=$firstInferenceMillis " +
                "averageInferenceMs=${backend.averageInferenceMillis} " +
                "documentChunks=${vectorization.chunkCount} " +
                "documentVectorizeMs=${vectorization.durationMillis} " +
                "topScore=${hits.first().similarity}",
        )
    }

    @Test
    fun unrelatedQueriesReturnNoHitsWithRealModel() = runBlocking {
        val assets = InstrumentationRegistry.getInstrumentation().targetContext.assets
        val backend = OnnxEmbeddingBackend(assets)
        val store = TestStore().apply {
            add(
                KnowledgeDocument(
                    id = "doc-1",
                    name = "团队约定.txt",
                    format = DocumentFormat.Txt,
                    chunkCount = 3,
                    importedAt = 1L,
                ),
                listOf(budgetText, weatherText, retrievalText),
            )
        }
        val indexer = DocumentIndexer(store = store, vectorStore = store, backend = backend)
        indexer.index(store.document("doc-1"))
        val search = KnowledgeSearch(store = store, vectorStore = store, backend = backend)

        val unrelatedQueries = listOf(
            "量子色动力学的渐近自由",
            "如何做红烧肉",
            "明天股票会涨吗",
        )
        val hitsPerQuery = unrelatedQueries.map { query ->
            query to search.search(query)
        }
        println(
            "EMBEDDING_UNRELATED " + hitsPerQuery.joinToString(" ") { (query, hits) ->
                "query=$query hits=${hits.size} scores=${hits.map { it.similarity }}"
            },
        )
        assertTrue(hitsPerQuery.all { (_, hits) -> hits.isEmpty() })
    }

    private class TestStore : DocumentStore, ChunkVectorStore {
        private val documents = linkedMapOf<String, KnowledgeDocument>()
        private val chunks = linkedMapOf<String, List<DocumentChunk>>()
        private val vectors = linkedMapOf<String, List<ChunkVector>>()

        fun add(document: KnowledgeDocument, texts: List<String>) {
            documents[document.id] = document
            chunks[document.id] = texts.mapIndexed { index, text ->
                DocumentChunk(documentId = document.id, index = index, text = text)
            }
        }

        fun document(id: String): KnowledgeDocument = requireNotNull(documents[id])

        override suspend fun listDocuments(): List<KnowledgeDocument> = documents.values.toList()

        override suspend fun listChunks(documentId: String): List<DocumentChunk> =
            chunks[documentId].orEmpty()

        override suspend fun addDocument(
            document: KnowledgeDocument,
            chunks: List<DocumentChunk>,
        ) {
            documents[document.id] = document
            this.chunks[document.id] = chunks
        }

        override suspend fun deleteDocument(documentId: String) {
            documents.remove(documentId)
            chunks.remove(documentId)
            vectors.remove(documentId)
        }

        override suspend fun listVectors(documentId: String): List<ChunkVector> =
            vectors[documentId].orEmpty()

        override suspend fun replaceVectors(
            documentId: String,
            vectors: List<ChunkVector>,
        ) {
            this.vectors[documentId] = vectors
        }

        override suspend fun deleteVectors(documentId: String) {
            vectors.remove(documentId)
        }
    }
}
