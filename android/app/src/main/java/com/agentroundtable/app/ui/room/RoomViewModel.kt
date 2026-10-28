package com.agentroundtable.app.ui.room

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.room.ConnectionState
import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.core.room.RoomView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class RoomViewModel(
    private val roundtableId: String,
    private val controller: RoomController,
    private val api: ApiClient,
    private val cache: RoomCache,
    private val sessionProvider: suspend () -> String?,
) : ViewModel() {
    val view: StateFlow<RoomView> = controller.view
    val connection: StateFlow<ConnectionState> = controller.connection

    private val _deleted = MutableStateFlow(false)
    val deleted: StateFlow<Boolean> = _deleted.asStateFlow()

    private val _deleteError = MutableStateFlow<String?>(null)
    val deleteError: StateFlow<String?> = _deleteError.asStateFlow()

    init {
        viewModelScope.launch {
            val sessionId = sessionProvider() ?: return@launch
            controller.connect(
                scope = viewModelScope,
                roundtableId = roundtableId,
                sessionId = sessionId,
            )
        }
    }

    /**
     * 提前结束并删除圆桌。先写墓碑再删除缓存，保证即使后续清理失败，
     * 恢复路径也不会把已删除内容再显示出来。
     */
    fun delete() {
        viewModelScope.launch {
            val sessionId = sessionProvider()
            if (sessionId == null) {
                _deleteError.value = "还没有可用的匿名会话。"
                return@launch
            }
            when (val result = api.deleteRoundtable(sessionId, roundtableId)) {
                is ApiResult.Failure -> _deleteError.value = result.message
                is ApiResult.Success -> {
                    controller.disconnect()
                    cache.delete(roundtableId)
                    _deleted.value = true
                }
            }
        }
    }

    override fun onCleared() {
        controller.disconnect()
        super.onCleared()
    }
}
