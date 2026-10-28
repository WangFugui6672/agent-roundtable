package com.agentroundtable.app.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.app.data.knowledge.DocumentSourceReader
import com.agentroundtable.core.knowledge.ImportResult
import com.agentroundtable.core.knowledge.KnowledgeBase
import com.agentroundtable.core.knowledge.KnowledgeDocument
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class LibraryUiState(
    val isLoading: Boolean = true,
    val documents: List<KnowledgeDocument> = emptyList(),
    val isImporting: Boolean = false,
    val errorMessage: String? = null,
)

class LibraryViewModel(
    private val knowledgeBase: KnowledgeBase,
    private val sourceReader: DocumentSourceReader,
    private val workDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : ViewModel() {
    private val _state = MutableStateFlow(LibraryUiState())
    val state: StateFlow<LibraryUiState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            loadDocuments(showLoading = _state.value.documents.isEmpty())
        }
    }

    /** 导入所选文件；读取、解析、切分与保存都不阻塞主线程。 */
    fun import(sourceId: String) {
        if (_state.value.isImporting) return
        viewModelScope.launch {
            _state.update { it.copy(isImporting = true, errorMessage = null) }
            val failure = try {
                val source = sourceReader.read(sourceId)
                // 解析与切分可能耗时，放到后台线程，保证进度可见且界面不卡顿。
                when (val result = withContext(workDispatcher) { knowledgeBase.import(source) }) {
                    is ImportResult.Imported -> null
                    is ImportResult.Failed -> result.message
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                error.message ?: "导入失败，请重试。"
            }
            _state.update { it.copy(isImporting = false, errorMessage = failure) }
            loadDocuments(showLoading = false)
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
