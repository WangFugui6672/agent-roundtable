package com.agentroundtable.app.ui.library

import com.agentroundtable.app.data.knowledge.DocumentReadException
import com.agentroundtable.app.data.knowledge.DocumentSourceReader
import com.agentroundtable.app.data.knowledge.EmbeddingStats
import com.agentroundtable.core.knowledge.ChunkVector
import com.agentroundtable.core.knowledge.ChunkVectorStore
import com.agentroundtable.core.knowledge.DocumentChunk
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.DocumentIndexer
import com.agentroundtable.core.knowledge.DocumentParser
import com.agentroundtable.core.knowledge.DocumentStore
import com.agentroundtable.core.knowledge.EmbeddingBackend
import com.agentroundtable.core.knowledge.ImportSource
import com.agentroundtable.core.knowledge.KnowledgeBase
import com.agentroundtable.core.knowledge.KnowledgeDocument
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeDocumentStore : DocumentStore, ChunkVectorStore {
    val documents = linkedMapOf<String, KnowledgeDocument>()
    val chunks = linkedMapOf<String, List<DocumentChunk>>()
    val vectors = linkedMapOf<String, List<ChunkVector>>()

    override suspend fun listDocuments(): List<KnowledgeDocument> = documents.values.toList()

    override suspend fun listChunks(documentId: String): List<DocumentChunk> =
        chunks[documentId].orEmpty()

    override suspend fun addDocument(document: KnowledgeDocument, chunks: List<DocumentChunk>) {
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

    override suspend fun replaceVectors(documentId: String, vectors: List<ChunkVector>) {
        this.vectors[documentId] = vectors
    }

    override suspend fun deleteVectors(documentId: String) {
        vectors.remove(documentId)
    }
}

private class FakeEmbeddingBackend(
    private val vectorsByText: Map<String, FloatArray> = emptyMap(),
    private val fail: Boolean = false,
) : EmbeddingBackend {
    override suspend fun embed(texts: List<String>): List<FloatArray> {
        if (fail) throw IllegalStateException("model missing")
        return texts.map { text -> vectorsByText[text] ?: floatArrayOf(1f, 0f) }
    }
}

private class GatedEmbeddingBackend(
    private val gate: CompletableDeferred<Unit>,
    private val vector: FloatArray = floatArrayOf(1f, 0f),
) : EmbeddingBackend {
    override suspend fun embed(texts: List<String>): List<FloatArray> {
        gate.await()
        return texts.map { vector }
    }
}

private class FakeSourceReader(
    private val readSource: suspend (String) -> ImportSource,
) : DocumentSourceReader {
    override suspend fun read(sourceId: String): ImportSource = readSource(sourceId)
}

class LibraryViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `importing shows progress and then lists the stored document`() = runTest(dispatcher) {
        val gate = CompletableDeferred<Unit>()
        val store = FakeDocumentStore()
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(
                parser = DocumentParser { "只有一段。" },
                store = store,
                clock = { 7L },
                idGenerator = { "doc-1" },
            ),
            sourceReader = FakeSourceReader {
                gate.await()
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.import("content://notes")
        runCurrent()
        assertTrue(viewModel.state.value.isImporting)

        gate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.state.value.isImporting)
        assertEquals(1, viewModel.state.value.documents.size)
        assertEquals("笔记.txt", viewModel.state.value.documents.single().name)
        assertEquals(1, viewModel.state.value.documents.single().chunkCount)
    }

    @Test
    fun `a read failure is surfaced without adding a document`() = runTest(dispatcher) {
        val store = FakeDocumentStore()
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(parser = DocumentParser { "" }, store = store),
            sourceReader = FakeSourceReader {
                throw DocumentReadException("文件超过 20 MB，暂时无法导入。")
            },
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.import("content://huge")
        advanceUntilIdle()

        assertFalse(viewModel.state.value.isImporting)
        assertTrue(viewModel.state.value.documents.isEmpty())
        assertEquals("文件超过 20 MB，暂时无法导入。", viewModel.state.value.errorMessage)
    }

    @Test
    fun `deleting a document also removes its chunks from the list`() = runTest(dispatcher) {
        val store = FakeDocumentStore()
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(
                parser = DocumentParser { "甲".repeat(300) + "\n\n" + "乙".repeat(300) },
                store = store,
                idGenerator = { "doc-1" },
            ),
            sourceReader = FakeSourceReader {
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()
        viewModel.import("content://notes")
        advanceUntilIdle()
        assertEquals(2, viewModel.state.value.documents.single().chunkCount)

        viewModel.delete("doc-1")
        advanceUntilIdle()

        assertTrue(viewModel.state.value.documents.isEmpty())
        assertTrue(store.chunks["doc-1"].isNullOrEmpty())
    }

    @Test
    fun `导入后自动完成文档块向量化并展示实测数据`() = runTest(dispatcher) {
        val store = FakeDocumentStore()
        val clockValues = ArrayDeque(listOf(100L, 175L))
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(
                parser = DocumentParser { "只有一段。" },
                store = store,
                idGenerator = { "doc-1" },
            ),
            sourceReader = FakeSourceReader {
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            documentIndexer = DocumentIndexer(
                store = store,
                vectorStore = store,
                backend = FakeEmbeddingBackend(
                    mapOf("只有一段。" to floatArrayOf(1f, 0f)),
                ),
                clock = { clockValues.removeFirst() },
            ),
            embeddingStats = {
                EmbeddingStats(
                    modelLoadMillis = 120L,
                    lastInferenceMillis = 30L,
                    averageInferenceMillis = 28L,
                )
            },
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.import("content://notes")
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(1, state.documents.size)
        assertNull(state.errorMessage)
        assertNull(state.noticeMessage)
        assertNull(state.vectorization)
        assertEquals(1, store.vectors["doc-1"]?.size)
        assertTrue(state.embedding.available)
        assertEquals(120L, state.embedding.modelLoadMillis)
        assertEquals(28L, state.embedding.inferenceMillis)
        assertEquals("笔记.txt", state.embedding.lastDocumentName)
        assertEquals(1, state.embedding.lastDocumentChunkCount)
        assertEquals(75L, state.embedding.lastDocumentDurationMillis)
    }

    @Test
    fun `导入后展示文档块向量化进度`() = runTest(dispatcher) {
        val gate = CompletableDeferred<Unit>()
        val store = FakeDocumentStore()
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(
                parser = DocumentParser { "只有一段。" },
                store = store,
                idGenerator = { "doc-1" },
            ),
            sourceReader = FakeSourceReader {
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            documentIndexer = DocumentIndexer(
                store = store,
                vectorStore = store,
                backend = GatedEmbeddingBackend(gate),
            ),
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.import("content://notes")
        advanceUntilIdle()

        val progress = viewModel.state.value.vectorization
        assertNotNull(progress)
        assertEquals("笔记.txt", progress?.documentName)
        assertEquals(0, progress?.completedChunks)
        assertEquals(1, progress?.totalChunks)
        assertEquals(0f, progress?.fraction ?: -1f, 0f)

        gate.complete(Unit)
        advanceUntilIdle()

        assertNull(viewModel.state.value.vectorization)
        assertEquals(1, store.vectors["doc-1"]?.size)
    }

    @Test
    fun `模型初始化失败时降级为无检索但资料库仍可正常使用`() = runTest(dispatcher) {
        val store = FakeDocumentStore()
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(
                parser = DocumentParser { "只有一段。" },
                store = store,
                idGenerator = { "doc-1" },
            ),
            sourceReader = FakeSourceReader {
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            documentIndexer = DocumentIndexer(
                store = store,
                vectorStore = store,
                backend = FakeEmbeddingBackend(fail = true),
            ),
            workDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.import("content://notes")
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals(1, state.documents.size)
        assertNull(state.errorMessage)
        assertNull(state.vectorization)
        assertFalse(state.embedding.available)
        assertEquals("端侧检索不可用，资料库仍可正常使用。", state.noticeMessage)
        assertTrue(store.vectors.isEmpty())
    }

    @Test
    fun `启动时为尚未向量化的旧文档补做向量化`() = runTest(dispatcher) {
        val store = FakeDocumentStore()
        store.addDocument(
            KnowledgeDocument(
                id = "old",
                name = "旧文档.txt",
                format = DocumentFormat.Txt,
                chunkCount = 1,
                importedAt = 1L,
            ),
            listOf(DocumentChunk(documentId = "old", index = 0, text = "旧内容")),
        )
        val viewModel = LibraryViewModel(
            knowledgeBase = KnowledgeBase(parser = DocumentParser { "" }, store = store),
            sourceReader = FakeSourceReader {
                ImportSource("笔记.txt", "text/plain", "x".toByteArray())
            },
            documentIndexer = DocumentIndexer(
                store = store,
                vectorStore = store,
                backend = FakeEmbeddingBackend(
                    mapOf("旧内容" to floatArrayOf(0f, 1f)),
                ),
            ),
            embeddingStats = { EmbeddingStats(modelLoadMillis = 5L) },
            workDispatcher = dispatcher,
        )

        advanceUntilIdle()

        assertEquals(1, store.vectors["old"]?.size)
        assertEquals("旧文档.txt", viewModel.state.value.embedding.lastDocumentName)
    }
}
