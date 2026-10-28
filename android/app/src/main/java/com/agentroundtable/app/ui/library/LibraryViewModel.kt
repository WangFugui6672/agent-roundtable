package com.agentroundtable.app.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.app.data.knowledge.DocumentSourceReader
import com.agentroundtable.app.data.knowledge.EmbeddingStats
import com.agentroundtable.core.knowledge.DocumentIndexer
import com.agentroundtable.core.knowledge.ImportResult
import com.agentroundtable.core.knowledge.KnowledgeBase
import com.agentroundtable.core.knowledge.KnowledgeDocument
import com.agentroundtable.core.knowledge.VectorizationResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** 文档块向量化进度；界面据此展示可感知的进度条。 */
data class VectorizationUiState(
    val documentName: String,
    val completedChunks: Int,
    val totalChunks: Int,
) {
    val fraction: Float
        get() = if (totalChunks <= 0) 1f else completedChunks.toFloat() / totalChunks
}

/** 端侧嵌入的实测数据；模型不可用时只展示降级提示。 */
data class EmbeddingUiState(
    val available: Boolean = true,
    val modelLoadMillis: Long? = null,
    val inferenceMillis: Long? = null,
    val lastDocumentName: String? = null,
    val lastDocumentChunkCount: Int = 0,
    val lastDocumentDurationMillis: Long? = null,
) {
    val hasMeasurements: Boolean
        get() = !available || modelLoadMillis != null || lastDocumentName != null
}

data class LibraryUiState(
    val isLoading: Boolean = true,
    val documents: List<KnowledgeDocument> = emptyList(),
    val isImporting: Boolean = false,
    val vectorization: VectorizationUiState? = null,
    val embedding: EmbeddingUiState = EmbeddingUiState(),
    val errorMessage: String? = null,
    val noticeMessage: String? = null,
)

class LibraryViewModel(
    private val knowledgeBase: KnowledgeBase,
    private val sourceReader: DocumentSourceReader,
    private val documentIndexer: DocumentIndexer? = null,
    private val embeddingStats: () -> EmbeddingStats = { EmbeddingStats() },
    private val workDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : ViewModel() {
    private val _state = MutableStateFlow(LibraryUiState())
    val state: StateFlow<LibraryUiState> = _state.asStateFlow()

    private val indexingMutex = Mutex()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            loadDocuments(showLoading = _state.value.documents.isEmpty())
            indexPendingDocuments()
        }
    }

    /** 导入所选文件；读取、解析、切分、保存与向量化都不阻塞主线程。 */
    fun import(sourceId: String) {
        if (_state.value.isImporting) return
        viewModelScope.launch {
            _state.update { it.copy(isImporting = true, errorMessage = null, noticeMessage = null) }
            val result = try {
                val source = sourceReader.read(sourceId)
                // 解析与切分可能耗时，放到后台线程，保证进度可见且界面不卡顿。
                withContext(workDispatcher) { knowledgeBase.import(source) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                ImportResult.Failed(error.message ?: "导入失败，请重试。")
            }
            _state.update {
                it.copy(
                    isImporting = false,
                    errorMessage = (result as? ImportResult.Failed)?.message,
                )
            }
            loadDocuments(showLoading = false)
            if (result is ImportResult.Imported) {
                indexPendingDocuments()
            }
        }
    }

    fun delete(documentId: String) {
        viewModelScope.launch {
            val failure = try {
                knowledgeBase.delete(documentId)
                null
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                "删除失败，请重试。"
            }
            _state.update { it.copy(errorMessage = failure) }
            loadDocuments(showLoading = false)
        }
    }

    fun dismissError() {
        _state.update { it.copy(errorMessage = null) }
    }

    fun dismissNotice() {
        _state.update { it.copy(noticeMessage = null) }
    }

    /**
     * 为尚未完成向量化的文档补做向量化。
     *
     * 串行执行，避免重复推理；新导入的文档会排在同一把锁之后再检查一次。
     * 模型初始化失败时只记录降级提示，资料库列表与删除等功能继续可用。
     */
    private fun indexPendingDocuments() {
        val indexer = documentIndexer ?: return
        viewModelScope.launch {
            indexingMutex.withLock {
                while (true) {
                    val pending = try {
                        indexer.pendingDocuments()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        markEmbeddingUnavailable()
                        return@withLock
                    }
                    val document = pending.firstOrNull() ?: return@withLock
                    if (!indexDocument(indexer, document)) return@withLock
                }
            }
        }
    }

    private suspend fun indexDocument(
        indexer: DocumentIndexer,
        document: KnowledgeDocument,
    ): Boolean {
        _state.update {
            it.copy(
                vectorization = VectorizationUiState(
                    documentName = document.name,
                    completedChunks = 0,
                    totalChunks = document.chunkCount,
                ),
                embedding = it.embedding.copy(available = true),
            )
        }

        val result = indexer.index(document) { progress ->
            _state.update {
                it.copy(
                    vectorization = VectorizationUiState(
                        documentName = progress.documentName,
                        completedChunks = progress.completedChunks,
                        totalChunks = progress.totalChunks,
                    ),
                )
            }
        }

        return when (result) {
            is VectorizationResult.Completed -> {
                val stats = embeddingStats()
                _state.update {
                    it.copy(
                        vectorization = null,
                        noticeMessage = null,
                        embedding = EmbeddingUiState(
                            available = true,
                            modelLoadMillis = stats.modelLoadMillis,
                            inferenceMillis = stats.averageInferenceMillis
                                ?: stats.lastInferenceMillis,
                            lastDocumentName = result.documentName,
                            lastDocumentChunkCount = result.chunkCount,
                            lastDocumentDurationMillis = result.durationMillis,
                        ),
                    )
                }
                true
            }

            is VectorizationResult.Failed -> {
                // 文档在向量化期间被删除时，外键失败不是嵌入后端的问题。
                val stillExists = documentStillExists(document.id)
                if (stillExists) markEmbeddingUnavailable()
                !stillExists
            }
        }
    }

    private suspend fun documentStillExists(documentId: String): Boolean = try {
        knowledgeBase.documents().any { it.id == documentId }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        true
    }

    private fun markEmbeddingUnavailable() {
        _state.update {
            it.copy(
                vectorization = null,
                noticeMessage = "端侧检索不可用，资料库仍可正常使用。",
                embedding = it.embedding.copy(available = false),
            )
        }
    }

    private suspend fun loadDocuments(showLoading: Boolean) {
        if (showLoading) {
            _state.update { it.copy(isLoading = true) }
        }
        try {
            val documents = knowledgeBase.documents()
            _state.update { it.copy(isLoading = false, documents = documents) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _state.update {
                it.copy(
                    isLoading = false,
                    errorMessage = "读取资料库失败，请重试。",
                )
            }
        }
    }
}
