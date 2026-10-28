package com.agentroundtable.core.knowledge

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class InMemoryDocumentStore : DocumentStore {
    val documents = linkedMapOf<String, KnowledgeDocument>()
    val chunks = linkedMapOf<String, List<DocumentChunk>>()
    var failNextWrite = false

    override suspend fun listDocuments(): List<KnowledgeDocument> =
        documents.values.sortedByDescending { it.importedAt }

    override suspend fun listChunks(documentId: String): List<DocumentChunk> =
        chunks[documentId].orEmpty()

    override suspend fun addDocument(document: KnowledgeDocument, chunks: List<DocumentChunk>) {
        if (failNextWrite) {
            failNextWrite = false
            throw IllegalStateException("disk full")
        }
        documents[document.id] = document
        this.chunks[document.id] = chunks.sortedBy { it.index }
    }

    override suspend fun deleteDocument(documentId: String) {
        documents.remove(documentId)
        chunks.remove(documentId)
    }
}

class KnowledgeBaseTest {
    @Test
    fun `importing a text document stores its chunks and chunk count`() = runTest {
        val store = InMemoryDocumentStore()
        val first = "甲".repeat(300)
        val second = "乙".repeat(300)
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { "$first\n\n$second" },
            store = store,
            clock = { 42L },
            idGenerator = { "doc-1" },
        )

        val result = knowledgeBase.import(
            ImportSource("笔记.txt", "text/plain", "ignored".toByteArray()),
        )

        result as ImportResult.Imported
        assertEquals("doc-1", result.document.id)
        assertEquals("笔记.txt", result.document.name)
        assertEquals(DocumentFormat.Txt, result.document.format)
        assertEquals(2, result.document.chunkCount)
        assertEquals(42L, result.document.importedAt)
        assertEquals(2, store.listChunks("doc-1").size)
        assertEquals(listOf(0, 1), store.listChunks("doc-1").map { it.index })
    }

    @Test
    fun `a parser failure leaves no document or chunk behind`() = runTest {
        val store = InMemoryDocumentStore()
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { throw DocumentParseException("PDF 已加密，无法提取文本。") },
            store = store,
        )

        val result = knowledgeBase.import(
            ImportSource("合同.pdf", "application/pdf", byteArrayOf(1, 2, 3)),
        )

        assertEquals(ImportResult.Failed("PDF 已加密，无法提取文本。"), result)
        assertTrue(store.listDocuments().isEmpty())
        assertTrue(store.listChunks("missing").isEmpty())
    }

    @Test
    fun `docx is rejected with a clear reason and never parsed`() = runTest {
        val store = InMemoryDocumentStore()
        var parserCalls = 0
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser {
                parserCalls++
                "should not be read"
            },
            store = store,
        )

        val result = knowledgeBase.import(
            ImportSource("方案.docx", DocumentFormat.DOCX_MIME_TYPE, byteArrayOf(1)),
        )

        result as ImportResult.Failed
        assertEquals(DocumentFormat.DOCX_UNSUPPORTED_REASON, result.message)
        assertEquals(0, parserCalls)
        assertTrue(store.listDocuments().isEmpty())
    }

    @Test
    fun `an unsupported format is rejected explicitly`() = runTest {
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { "should not be read" },
            store = InMemoryDocumentStore(),
        )

        val result = knowledgeBase.import(
            ImportSource("表格.csv", "text/csv", "a,b".toByteArray()),
        )

        result as ImportResult.Failed
        assertTrue(result.message.contains("不支持的文件格式"))
    }

    @Test
    fun `an empty file is rejected before parsing`() = runTest {
        var parserCalls = 0
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser {
                parserCalls++
                ""
            },
            store = InMemoryDocumentStore(),
        )

        val result = knowledgeBase.import(ImportSource("空.txt", "text/plain", byteArrayOf()))

        assertEquals(ImportResult.Failed("文件为空，没有可导入的内容。"), result)
        assertEquals(0, parserCalls)
    }

    @Test
    fun `text without content is rejected instead of storing empty chunks`() = runTest {
        val store = InMemoryDocumentStore()
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { "  \n\n \t " },
            store = store,
        )

        val result = knowledgeBase.import(
            ImportSource("空白.txt", "text/plain", "x".toByteArray()),
        )

        assertEquals(ImportResult.Failed("文档中没有可提取的文本。"), result)
        assertTrue(store.listDocuments().isEmpty())
    }

    @Test
    fun `a storage failure is reported and no document remains`() = runTest {
        val store = InMemoryDocumentStore().apply { failNextWrite = true }
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { "内容。" },
            store = store,
        )

        val result = knowledgeBase.import(
            ImportSource("笔记.txt", "text/plain", "x".toByteArray()),
        )

        assertEquals(ImportResult.Failed("保存资料失败，请重试。"), result)
        assertTrue(store.listDocuments().isEmpty())
    }

    @Test
    fun `deleting a document removes its chunks`() = runTest {
        val store = InMemoryDocumentStore()
        val knowledgeBase = KnowledgeBase(
            parser = DocumentParser { "甲".repeat(300) + "\n\n" + "乙".repeat(300) },
            store = store,
            idGenerator = { "doc-1" },
        )
        knowledgeBase.import(ImportSource("笔记.txt", "text/plain", "x".toByteArray()))
        assertEquals(1, store.listDocuments().size)
        assertEquals(2, store.listChunks("doc-1").size)

        knowledgeBase.delete("doc-1")

        assertTrue(store.listDocuments().isEmpty())
        assertTrue(store.listChunks("doc-1").isEmpty())
    }

    @Test
    fun `format detection prefers the file extension over a generic mime type`() {
        assertEquals(DocumentFormat.Markdown, DocumentFormat.detect("说明.md", "text/plain"))
        assertEquals(DocumentFormat.Markdown, DocumentFormat.detect("README.MARKDOWN", null))
        assertEquals(DocumentFormat.Pdf, DocumentFormat.detect("扫描件.pdf", null))
        assertEquals(DocumentFormat.Txt, DocumentFormat.detect("notes.txt", "text/plain"))
        assertEquals(DocumentFormat.Pdf, DocumentFormat.detect("payload", "application/pdf"))
        assertEquals(DocumentFormat.Txt, DocumentFormat.detect("payload", "text/plain; charset=utf-8"))
        assertNull(DocumentFormat.detect("方案.docx", DocumentFormat.DOCX_MIME_TYPE))
        assertNull(DocumentFormat.detect("archive.zip", "application/zip"))
    }
}
