package com.agentroundtable.core.knowledge

/**
 * 资料库的存储接缝。
 *
 * [addDocument] 与 [deleteDocument] 必须是原子的：导入失败不得留下半成品条目，
 * 删除文档必须同时删除它的全部文档块。真实实现由 `:app` 的 Room 提供。
 *
 * 检索（#32）从 [listChunks] 读取文档块，并关联之后保存的向量。
 */
interface DocumentStore {
    suspend fun listDocuments(): List<KnowledgeDocument>

    suspend fun listChunks(documentId: String): List<DocumentChunk>

    suspend fun addDocument(document: KnowledgeDocument, chunks: List<DocumentChunk>)

    suspend fun deleteDocument(documentId: String)
}
