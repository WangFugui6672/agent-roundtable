package com.agentroundtable.app.ui.library

import com.agentroundtable.app.data.knowledge.DocumentReadException
import com.agentroundtable.app.data.knowledge.DocumentSourceReader
import com.agentroundtable.core.knowledge.DocumentChunk
import com.agentroundtable.core.knowledge.DocumentParser
import com.agentroundtable.core.knowledge.DocumentStore
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
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeDocumentStore : DocumentStore {
    val documents = linkedMapOf<String, KnowledgeDocument>()
    val chunks = linkedMapOf<String, List<DocumentChunk>>()

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
}
