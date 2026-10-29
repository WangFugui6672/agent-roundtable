package com.agentroundtable.app.data.knowledge

import androidx.room.withTransaction
import com.agentroundtable.core.knowledge.ChunkVector
import com.agentroundtable.core.knowledge.ChunkVectorStore
import com.agentroundtable.core.knowledge.DocumentChunk
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.DocumentStore
import com.agentroundtable.core.knowledge.KnowledgeDocument
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Room 实现的资料库存储；文档与文档块在同一事务中写入或删除。
 *
 * 同一个实例同时实现 [DocumentStore] 与 [ChunkVectorStore]，这样文档和向量共享
 * 一个数据库连接，删除文档时外键会级联清理文档块与向量。
 */
class RoomDocumentStore(
    private val database: KnowledgeDatabase,
) : DocumentStore, ChunkVectorStore {
    override suspend fun listDocuments(): List<KnowledgeDocument> =
        database.knowledgeDao().documents().map { it.toModel() }

    override suspend fun listChunks(documentId: String): List<DocumentChunk> =
        database.knowledgeDao().chunks(documentId).map { it.toModel() }

    override suspend fun addDocument(document: KnowledgeDocument, chunks: List<DocumentChunk>) {
        require(document.chunkCount == chunks.size) {
            "chunk count does not match stored chunks"
        }
        require(chunks.all { it.documentId == document.id }) {
            "chunk belongs to a different document"
        }
        database.withTransaction {
            database.knowledgeDao().insertDocument(document.toEntity())
            if (chunks.isNotEmpty()) {
                database.knowledgeDao().insertChunks(
                    chunks.sortedBy { it.index }.map { it.toEntity() },
                )
            }
        }
    }

    override suspend fun deleteDocument(documentId: String) {
        database.withTransaction {
            // 外键已经配置 CASCADE；显式删除让「文档块与向量一并删除」不依赖数据库设置。
            database.knowledgeDao().deleteVectors(documentId)
            database.knowledgeDao().deleteChunks(documentId)
            database.knowledgeDao().deleteDocument(documentId)
        }
    }

    override suspend fun listVectors(documentId: String): List<ChunkVector> =
        database.knowledgeDao().vectors(documentId).map { it.toModel() }

    override suspend fun replaceVectors(documentId: String, vectors: List<ChunkVector>) {
        require(vectors.all { it.documentId == documentId }) {
            "vector belongs to a different document"
        }
        database.withTransaction {
            database.knowledgeDao().deleteVectors(documentId)
            if (vectors.isNotEmpty()) {
                database.knowledgeDao().insertVectors(
                    vectors.sortedBy { it.chunkIndex }.map { it.toEntity() },
                )
            }
        }
    }

    override suspend fun deleteVectors(documentId: String) {
        database.knowledgeDao().deleteVectors(documentId)
    }

    private fun KnowledgeDocumentEntity.toModel() = KnowledgeDocument(
        id = id,
        name = name,
        format = DocumentFormat.fromWire(format)
            ?: error("unknown document format stored in database: $format"),
        chunkCount = chunkCount,
        importedAt = importedAt,
    )

    private fun DocumentChunkEntity.toModel() = DocumentChunk(
        documentId = documentId,
        index = chunkIndex,
        text = text,
    )

    private fun ChunkVectorEntity.toModel() = ChunkVector(
        documentId = documentId,
        chunkIndex = chunkIndex,
        values = embedding.toFloatArray().also { values ->
            require(values.size == dimension) {
                "stored chunk vector dimension does not match its payload"
            }
        },
    )

    private fun KnowledgeDocument.toEntity() = KnowledgeDocumentEntity(
        id = id,
        name = name,
        format = format.wireValue,
        chunkCount = chunkCount,
        importedAt = importedAt,
    )

    private fun DocumentChunk.toEntity() = DocumentChunkEntity(
        documentId = documentId,
        chunkIndex = index,
        text = text,
    )

    private fun ChunkVector.toEntity() = ChunkVectorEntity(
        documentId = documentId,
        chunkIndex = chunkIndex,
        embedding = values.toByteArray(),
        dimension = values.size,
    )

    private fun FloatArray.toByteArray(): ByteArray {
        val buffer = ByteBuffer.allocate(size * FLOAT_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        buffer.asFloatBuffer().put(this)
        return buffer.array()
    }

    private fun ByteArray.toFloatArray(): FloatArray {
        require(size % FLOAT_BYTES == 0) { "chunk vector payload is not a float array" }
        val buffer = ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(size / FLOAT_BYTES).also { buffer.asFloatBuffer().get(it) }
    }

    private companion object {
        const val FLOAT_BYTES = 4
    }
}
