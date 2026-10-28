package com.agentroundtable.app.ui.create

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.CreateRoundtableRules
import com.agentroundtable.core.CreateValidation
import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.model.AgentProfile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class CreateUiState(
    val topic: String = "",
    val profiles: List<AgentProfile> = emptyList(),
    val selectedProfileIds: List<String> = emptyList(),
    val isLoadingProfiles: Boolean = true,
    val isSubmitting: Boolean = false,
    val message: String? = null,
    val createdRoundtableId: String? = null,
)

class CreateViewModel(
    private val api: ApiClient,
    private val sessionProvider: suspend () -> String?,
    private val providerProvider: suspend () -> com.agentroundtable.core.model.ProviderMetadata? = { null },
) : ViewModel() {
    private val _state = MutableStateFlow(CreateUiState())
    val state: StateFlow<CreateUiState> = _state.asStateFlow()

    init {
        loadProfiles()
    }

    fun updateTopic(value: String) {
        _state.update { it.copy(topic = value, message = null) }
    }

    fun toggleProfile(profileId: String) {
        _state.update { current ->
            val selected = current.selectedProfileIds
            val next = if (profileId in selected) selected - profileId else selected + profileId
            current.copy(selectedProfileIds = next, message = null)
        }
    }

    fun submit() {
        val current = _state.value
        if (current.isSubmitting) return

        val topicCheck = CreateRoundtableRules.validateTopic(current.topic)
        if (topicCheck is CreateValidation.Invalid) {
            _state.update { it.copy(message = topicCheck.message) }
            return
        }
        val selectionCheck = CreateRoundtableRules.validateSelection(current.selectedProfileIds)
        if (selectionCheck is CreateValidation.Invalid) {
            _state.update { it.copy(message = selectionCheck.message) }
            return
        }

        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, message = null) }
            val sessionId = sessionProvider()
            if (sessionId == null) {
                _state.update { it.copy(isSubmitting = false, message = "还没有可用的匿名会话，请返回首页重试。") }
                return@launch
            }
            val result = api.createRoundtable(
                sessionId = sessionId,
                topic = current.topic.trim(),
                agentProfileIds = current.selectedProfileIds,
                provider = providerProvider(),
            )
            _state.update {
                when (result) {
                    is ApiResult.Failure -> it.copy(isSubmitting = false, message = result.message)
                    is ApiResult.Success -> it.copy(
                        isSubmitting = false,
                        createdRoundtableId = result.value.id,
                    )
                }
            }
        }
    }

    fun consumeMessage() {
        _state.update { it.copy(message = null) }
    }

    /** 消费掉「已创建」信号，避免再次进入创建页时被立刻弹回首页。 */
    fun consumeCreated() {
        _state.update { it.copy(createdRoundtableId = null) }
    }

    private fun loadProfiles() {
        viewModelScope.launch {
            val result = api.listAgentProfiles()
            _state.update {
                when (result) {
                    is ApiResult.Failure -> it.copy(isLoadingProfiles = false, message = result.message)
                    is ApiResult.Success -> it.copy(
                        profiles = result.value,
                        isLoadingProfiles = false,
                    )
                }
            }
        }
    }
}
