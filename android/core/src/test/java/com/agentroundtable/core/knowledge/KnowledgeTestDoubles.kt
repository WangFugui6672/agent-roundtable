package com.agentroundtable.core.knowledge

/** 检索与向量化测试共用的内存实现；不依赖 Room 或真实模型文件。 */
class InMemoryRetrievalStore : DocumentStore, ChunkVectorStore {
    val documents = linkedMapOf<String, KnowledgeDocument>()
    private val chunks = linkedMapOf<String, List<DocumentChunk>>()
    private val vectors = linkedMapOf<String, List<ChunkVector>>()

    var replaceVectorCalls: Int = 0
        private set

    fun add(document: KnowledgeDocument, chunkTexts: List<String>) {
        documents[document.id] = document
        chunks[document.id] = chunkTexts.mapIndexed { index, text ->
            DocumentChunk(documentId = document.id, index = index, text = text)
        }
    }

    fun putVectors(documentId: String, stored: List<ChunkVector>) {
        vectors[documentId] = stored
    }

    fun vectorsOf(documentId: String): List<ChunkVector> = vectors[documentId].orEmpty()

    override suspend fun listDocuments(): List<KnowledgeDocument> = documents.values.toList()

    override suspend fun listChunks(documentId: String): List<DocumentChunk> =
        chunks[documentId].orEmpty().sortedBy { it.index }

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
        replaceVectorCalls++
        this.vectors[documentId] = vectors
    }

    override suspend fun deleteVectors(documentId: String) {
        vectors.remove(documentId)
    }
}

/** 可预测的假嵌入后端：按文本查表返回固定向量，可记录调用并模拟失败。 */
class FakeEmbeddingBackend(
    private val vectorsByText: Map<String, FloatArray> = emptyMap(),
    private val defaultVector: FloatArray = floatArrayOf(1f, 0f),
) : EmbeddingBackend {
    val calls = mutableListOf<List<String>>()
    var failure: Exception? = null

    override suspend fun embed(texts: List<String>): List<FloatArray> {
        calls += texts
        failure?.let { throw it }
        return texts.map { text -> vectorsByText[text] ?: defaultVector }
    }
}

fun knowledgeDocument(
    id: String,
    name: String = "文档-$id",
    chunkCount: Int = 0,
): KnowledgeDocument = KnowledgeDocument(
    id = id,
    name = name,
    format = DocumentFormat.Txt,
    chunkCount = chunkCount,
    importedAt = 0L,
)
