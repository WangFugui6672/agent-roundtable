package com.agentroundtable.app.ui.room

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.room.ConnectionState
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.core.room.RoomView
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class RoomViewModel(
    private val roundtableId: String,
    private val controller: RoomController,
    private val sessionProvider: suspend () -> String?,
) : ViewModel() {
    val view: StateFlow<RoomView> = controller.view
    val connection: StateFlow<ConnectionState> = controller.connection

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

    override fun onCleared() {
        controller.disconnect()
        super.onCleared()
    }
}
