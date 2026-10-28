package com.agentroundtable.app.data.knowledge

import androidx.room.withTransaction
import com.agentroundtable.core.knowledge.DocumentChunk
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.DocumentStore
import com.agentroundtable.core.knowledge.KnowledgeDocument

/** Room 实现的资料库存储；文档与文档块在同一事务中写入或删除。 */
class RoomDocumentStore(
    private val database: KnowledgeDatabase,
) : DocumentStore {
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
            // 外键已经配置 CASCADE；显式删除让「文档块一并删除」不依赖数据库设置。
            database.knowledgeDao().deleteChunks(documentId)
            database.knowledgeDao().deleteDocument(documentId)
        }
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
}
