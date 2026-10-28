package com.agentroundtable.app.ui.provider

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.provider.ProviderCheckOutcome
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderKind
import com.agentroundtable.core.provider.ProviderProbe
import com.agentroundtable.core.provider.ProviderSaveResult
import com.agentroundtable.core.provider.ProviderSettings
import com.agentroundtable.core.provider.ProviderState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ProviderUiState(
    val kind: ProviderKind = ProviderKind.DeepSeek,
    val baseUrl: String = ProviderKind.DeepSeek.defaultBaseUrl,
    val model: String = ProviderKind.DeepSeek.defaultModel,
    val apiKey: String = "",
    val hasStoredKey: Boolean = false,
    val saved: ProviderState = ProviderState(),
    val message: String? = null,
    val probeOutcome: ProviderCheckOutcome? = null,
    val isBusy: Boolean = false,
    val noticeAcknowledged: Boolean = true,
)

class ProviderViewModel(
    private val settings: ProviderSettings,
    private val probe: ProviderProbe,
) : ViewModel() {
    private val _state = MutableStateFlow(ProviderUiState())
    val state: StateFlow<ProviderUiState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            val loaded = settings.load()
            _state.update { current ->
                val configuration = loaded.configuration
                current.copy(
                    kind = configuration?.kind ?: current.kind,
                    baseUrl = configuration?.baseUrl ?: current.baseUrl,
                    model = configuration?.model ?: current.model,
                    hasStoredKey = loaded.hasKey,
                    saved = loaded,
                    noticeAcknowledged = loaded.noticeAcknowledged,
                )
            }
        }
    }

    fun selectKind(kind: ProviderKind) {
        _state.update {
            it.copy(
                kind = kind,
                baseUrl = if (kind.isCustom) "" else kind.defaultBaseUrl,
                model = if (kind.isCustom) "" else kind.defaultModel,
                apiKey = "",
                message = null,
                probeOutcome = null,
            )
        }
    }

    fun updateBaseUrl(value: String) {
        _state.update { it.copy(baseUrl = value, message = null, probeOutcome = null) }
    }

    fun updateModel(value: String) {
        _state.update { it.copy(model = value, message = null, probeOutcome = null) }
    }

    fun updateApiKey(value: String) {
        _state.update { it.copy(apiKey = value, message = null) }
    }

    fun save() {
        val current = _state.value
        if (current.isBusy) return
        viewModelScope.launch {
            _state.update { it.copy(isBusy = true, message = null) }
            val result = settings.save(
                ProviderConfiguration(current.kind, current.baseUrl, current.model),
                current.apiKey.takeIf { it.isNotBlank() },
            )
            val loaded = settings.load()
            _state.update {
                it.copy(
                    isBusy = false,
                    apiKey = "",
                    hasStoredKey = loaded.hasKey,
                    saved = loaded,
                    message = when (result) {
                        ProviderSaveResult.Saved -> "已保存。"
                        is ProviderSaveResult.Invalid -> result.message
                        is ProviderSaveResult.KeyRequired -> result.message
                    },
                )
            }
        }
    }

    fun probe() {
        val current = _state.value
        if (current.isBusy) return
        viewModelScope.launch {
            _state.update { it.copy(isBusy = true, probeOutcome = null, message = null) }
            val key = current.apiKey.takeIf { it.isNotBlank() } ?: settings.apiKey()
            if (key.isNullOrBlank()) {
                _state.update { it.copy(isBusy = false, message = "请先填写 API Key。") }
                return@launch
            }
            val outcome = probe.check(
                ProviderConfiguration(current.kind, current.baseUrl, current.model),
                key,
            )
            _state.update { it.copy(isBusy = false, probeOutcome = outcome) }
        }
    }

    fun delete() {
        viewModelScope.launch {
            settings.delete()
            _state.update {
                ProviderUiState(noticeAcknowledged = it.noticeAcknowledged, message = "已删除 Provider 配置。")
            }
        }
    }

    fun acknowledgeNotice() {
        viewModelScope.launch {
            settings.acknowledgeNotice()
            _state.update { it.copy(noticeAcknowledged = true) }
        }
    }
}
