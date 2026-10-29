package com.agentroundtable.core.knowledge

import kotlinx.coroutines.CancellationException

/**
 * 资料库检索用例：把用户查询变成向量，与已保存的文档块向量一起交给纯检索器。
 *
 * 空资料库、没有可检索的向量或空查询都直接返回空结果，不调用嵌入后端。
 * 嵌入后端不可用或检索过程失败时也返回空结果，调用方无需为「无检索」写异常分支。
 */
class KnowledgeSearch(
    private val store: DocumentStore,
    private val vectorStore: ChunkVectorStore,
    private val backend: EmbeddingBackend,
) {
    suspend fun search(query: String): List<RetrievalHit> {
        if (query.isBlank()) return emptyList()

        return try {
            val documents = store.listDocuments()
            if (documents.isEmpty()) return emptyList()

            val embeddedChunks = collectEmbeddedChunks(documents)
            if (embeddedChunks.isEmpty()) return emptyList()

            val queryVector = backend.embed(listOf(query)).firstOrNull() ?: return emptyList()
            Retriever.retrieve(queryVector, embeddedChunks)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun collectEmbeddedChunks(
        documents: List<KnowledgeDocument>,
    ): List<EmbeddedChunk> {
        val embeddedChunks = mutableListOf<EmbeddedChunk>()
        for (document in documents) {
            val vectors = vectorStore.listVectors(document.id)
            if (vectors.isEmpty()) continue
            val chunksByIndex = store.listChunks(document.id).associateBy { it.index }
            for (vector in vectors) {
                val chunk = chunksByIndex[vector.chunkIndex] ?: continue
                embeddedChunks += EmbeddedChunk(
                    documentId = document.id,
                    documentName = document.name,
                    chunkIndex = chunk.index,
                    text = chunk.text,
                    vector = vector.values,
                )
            }
        }
        return embeddedChunks
    }
}
