package com.agentroundtable.core.knowledge

import kotlinx.coroutines.CancellationException

/** 文档块的向量化进度。 */
data class VectorizationProgress(
    val documentId: String,
    val documentName: String,
    val completedChunks: Int,
    val totalChunks: Int,
) {
    val fraction: Float
        get() = if (totalChunks <= 0) 1f else completedChunks.toFloat() / totalChunks
}

/** 一次文档向量化的结果。失败不抛异常，调用方据此降级为无检索。 */
sealed interface VectorizationResult {
    data class Completed(
        val documentId: String,
        val documentName: String,
        val chunkCount: Int,
        val durationMillis: Long,
    ) : VectorizationResult

    data class Failed(
        val documentId: String,
        val documentName: String,
        val message: String,
    ) : VectorizationResult
}

/**
 * 把导入的文档块转换成向量并保存。
 *
 * 逐块调用 [EmbeddingBackend] 以便报告可感知的进度；全部成功后一次性替换该文档的
 * 向量，失败时保留旧向量，不留下半套数据。模型加载失败、推理异常等都会转成
 * [VectorizationResult.Failed]，不会向界面抛出。
 */
class DocumentIndexer(
    private val store: DocumentStore,
    private val vectorStore: ChunkVectorStore,
    private val backend: EmbeddingBackend,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    suspend fun index(
        document: KnowledgeDocument,
        onProgress: (VectorizationProgress) -> Unit = {},
    ): VectorizationResult {
        val startedAt = clock()
        return try {
            val chunks = store.listChunks(document.id)
            onProgress(progress(document, completedChunks = 0, totalChunks = chunks.size))

            val vectors = ArrayList<ChunkVector>(chunks.size)
            for (chunk in chunks) {
                val embedded = backend.embed(listOf(chunk.text))
                if (embedded.size != 1) {
                    return VectorizationResult.Failed(
                        documentId = document.id,
                        documentName = document.name,
                        message = "嵌入后端返回的向量数量与输入不一致。",
                    )
                }
                vectors += ChunkVector(
                    documentId = document.id,
                    chunkIndex = chunk.index,
                    values = embedded.single(),
                )
                onProgress(progress(document, vectors.size, chunks.size))
            }

            vectorStore.replaceVectors(document.id, vectors)
            VectorizationResult.Completed(
                documentId = document.id,
                documentName = document.name,
                chunkCount = chunks.size,
                durationMillis = (clock() - startedAt).coerceAtLeast(0L),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            VectorizationResult.Failed(
                documentId = document.id,
                documentName = document.name,
                message = error.message ?: "未知错误",
            )
        }
    }

    /** 尚未完成向量化的文档；用于补做旧版本导入或上次失败的文档。 */
    suspend fun pendingDocuments(): List<KnowledgeDocument> =
        store.listDocuments().filter { document ->
            val chunkCount = store.listChunks(document.id).size
            chunkCount > 0 && vectorStore.listVectors(document.id).size != chunkCount
        }

    private fun progress(
        document: KnowledgeDocument,
        completedChunks: Int,
        totalChunks: Int,
    ) = VectorizationProgress(
        documentId = document.id,
        documentName = document.name,
        completedChunks = completedChunks,
        totalChunks = totalChunks,
    )
}
