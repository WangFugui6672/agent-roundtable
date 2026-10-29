package com.agentroundtable.core.knowledge

/** 一个文档块的向量，通过文档 ID 与块内顺序位置关联 [DocumentChunk]。 */
data class ChunkVector(
    val documentId: String,
    val chunkIndex: Int,
    val values: FloatArray,
)

/**
 * 文档块向量的存储接缝。
 *
 * [replaceVectors] 必须在同一事务内替换该文档的全部向量：向量化失败时不能留下
 * 半套向量，否则检索会读到与文档块不一致的数据。
 */
interface ChunkVectorStore {
    suspend fun listVectors(documentId: String): List<ChunkVector>

    suspend fun replaceVectors(documentId: String, vectors: List<ChunkVector>)

    suspend fun deleteVectors(documentId: String)
}
