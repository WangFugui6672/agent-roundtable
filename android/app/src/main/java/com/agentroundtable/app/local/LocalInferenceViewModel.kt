package com.agentroundtable.app.local

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.local.LocalAvailability
import com.agentroundtable.core.local.LocalEngineState
import com.agentroundtable.core.local.LocalInferenceEngine
import com.agentroundtable.core.local.LocalInferenceEvent
import com.agentroundtable.core.local.LocalInferenceMetrics
import com.agentroundtable.core.local.LocalInferencePolicy
import com.agentroundtable.core.local.LocalLoadResult
import com.agentroundtable.core.local.LocalModel
import com.agentroundtable.core.local.LocalModelCatalog
import com.agentroundtable.core.local.LocalPrompt
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

sealed interface ModelPresence {
    data object NotDownloaded : ModelPresence

    data class Downloading(val progress: Float) : ModelPresence

    data object Verifying : ModelPresence

    data object Ready : ModelPresence

    data class Failed(val message: String) : ModelPresence
}

data class LocalModelUi(
    val model: LocalModel,
    val presence: ModelPresence,
    val availability: LocalAvailability,
)

data class LocalInferenceUiState(
    val models: List<LocalModelUi> = emptyList(),
    val selectedModelId: String = LocalModelCatalog.qwen05bQ4Km.id,
    val prompt: String = DEFAULT_PROMPT,
    val output: String = "",
    val status: String? = null,
    val error: String? = null,
    val metrics: LocalInferenceMetrics? = null,
    val metricsByModel: Map<String, LocalInferenceMetrics> = emptyMap(),
    val engineState: LocalEngineState = LocalEngineState.Uninitialized,
    val busy: Boolean = false,
    val generationRunning: Boolean = false,
) {
    val selectedModel: LocalModelUi?
        get() = models.firstOrNull { it.model.id == selectedModelId }

    val loadedModelId: String?
        get() = when (val state = engineState) {
            is LocalEngineState.Ready -> state.modelId
            is LocalEngineState.Generating -> state.modelId
            else -> null
        }

    val canGenerate: Boolean
        get() = loadedModelId == selectedModelId && !busy && !generationRunning
}

/**
 * 端侧推理界面状态。
 *
 * 这里只依赖 [LocalInferenceEngine]、[LocalModelStore] 与 [DeviceMemoryProbe]，
 * 不引用 llama.cpp；推理实现替换时界面无需修改。
 */
class LocalInferenceViewModel(
    private val engine: LocalInferenceEngine,
    private val modelStore: LocalModelStore,
    private val deviceMemory: DeviceMemoryProbe,
) : ViewModel() {
    private val _state = MutableStateFlow(LocalInferenceUiState())
    val state: StateFlow<LocalInferenceUiState> = _state.asStateFlow()

    private var generationJob: Job? = null

    init {
        viewModelScope.launch {
            engine.state.collect { engineState ->
                _state.update { it.copy(engineState = engineState) }
            }
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            val capability = deviceMemory.capability()
            val models = LocalModelCatalog.all.map { model ->
                val presence = when {
                    modelStore.isVerified(model) -> ModelPresence.Ready
                    modelStore.fileFor(model).isFile -> {
                        if (modelStore.verify(model)) ModelPresence.Ready
                        else {
                            modelStore.fileFor(model).delete()
                            ModelPresence.NotDownloaded
                        }
                    }
                    else -> ModelPresence.NotDownloaded
                }
                LocalModelUi(
                    model = model,
                    presence = presence,
                    availability = LocalInferencePolicy.availability(model, capability),
                )
            }
            _state.update { current ->
                val selected = current.selectedModelId.takeIf { id -> models.any { it.model.id == id } }
                    ?: models.firstOrNull { it.availability is LocalAvailability.Available }?.model?.id
                    ?: models.first().model.id
                current.copy(
                    models = models,
                    selectedModelId = selected,
                    error = current.error ?: models
                        .firstOrNull { it.model.id == selected }
                        ?.availability
                        ?.let { it as? LocalAvailability.Disabled }
                        ?.reason,
                )
            }
        }
    }

    fun selectModel(id: String) {
        _state.update { current ->
            if (current.generationRunning) current else current.copy(selectedModelId = id, error = null)
        }
    }

    fun updatePrompt(value: String) {
        _state.update { it.copy(prompt = value) }
    }

    fun download(id: String) {
        val model = LocalModelCatalog.byId(id) ?: return
        val current = _state.value
        if (current.busy || current.models.firstOrNull { it.model.id == id }?.availability is LocalAvailability.Disabled) {
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, status = "正在下载 ${model.quantization} 模型…") }
            setPresence(id, ModelPresence.Downloading(0f))
            try {
                modelStore.download(model) { progress ->
                    setPresence(id, ModelPresence.Downloading(progress))
                }
                setPresence(id, ModelPresence.Ready)
                _state.update {
                    it.copy(
                        busy = false,
                        selectedModelId = id,
                        status = "模型已下载并通过 SHA256 校验。",
                        error = null,
                    )
                }
            } catch (error: Exception) {
                val message = error.message ?: "模型下载失败。"
                setPresence(id, ModelPresence.Failed(message))
                _state.update {
                    it.copy(busy = false, status = null, error = message)
                }
            }
        }
    }

    fun importModel(uri: Uri) {
        if (_state.value.busy) return
        viewModelScope.launch {
            _state.update { it.copy(busy = true, status = "正在校验导入的模型文件…", error = null) }
            try {
                val imported = modelStore.import(uri)
                if (imported == null) {
                    _state.update {
                        it.copy(
                            busy = false,
                            status = null,
                            error = "文件与模型清单中的 SHA256 不匹配，未导入。",
                        )
                    }
                } else {
                    setPresence(imported.id, ModelPresence.Ready)
                    _state.update {
                        it.copy(
                            busy = false,
                            selectedModelId = imported.id,
                            status = "已导入并校验 ${imported.quantization} 模型。",
                            error = null,
                        )
                    }
                }
            } catch (error: Exception) {
                _state.update {
                    it.copy(busy = false, status = null, error = error.message ?: "导入失败。")
                }
            }
        }
    }

    fun loadSelected() {
        val current = _state.value
        val selected = current.selectedModel ?: return
        if (current.busy || current.generationRunning) return
        when (val availability = selected.availability) {
            is LocalAvailability.Disabled -> {
                _state.update { it.copy(error = availability.reason) }
                return
            }
            LocalAvailability.Available -> Unit
        }
        if (selected.presence != ModelPresence.Ready) {
            _state.update { it.copy(error = "请先下载或导入模型文件。") }
            return
        }
        if (current.loadedModelId == selected.model.id) {
            _state.update { it.copy(error = null, status = "模型已加载。") }
            return
        }
        if (current.loadedModelId != null) {
            _state.update { it.copy(error = "请先卸载当前模型，再加载其他模型。") }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, status = "正在加载模型…", error = null, metrics = null) }
            when (val result = engine.load(selected.model, modelStore.fileFor(selected.model).absolutePath)) {
                is LocalLoadResult.Failed -> _state.update {
                    it.copy(busy = false, status = null, error = result.message)
                }
                is LocalLoadResult.Loaded -> _state.update {
                    it.copy(
                        busy = false,
                        status = "模型已加载，耗时 ${result.loadMs} ms，参数 ${formatParams(result.parameterCount)}。",
                        error = null,
                    )
                }
            }
        }
    }

    fun generate() {
        val current = _state.value
        val selected = current.selectedModel ?: return
        if (!current.canGenerate) {
            _state.update { it.copy(error = "请先加载当前选中的模型。") }
            return
        }
        if (current.prompt.isBlank()) {
            _state.update { it.copy(error = "请输入要生成的内容。") }
            return
        }
        generationJob = viewModelScope.launch {
            _state.update {
                it.copy(
                    output = "",
                    metrics = null,
                    error = null,
                    status = "正在生成…（模型预填充中）",
                    generationRunning = true,
                )
            }
            engine.generate(LocalPrompt.qwenChatMl(SYSTEM_PROMPT, current.prompt)).collect { event ->
                when (event) {
                    is LocalInferenceEvent.Token -> _state.update {
                        it.copy(
                            output = it.output + event.text,
                            status = "正在生成…",
                        )
                    }
                    is LocalInferenceEvent.Completed -> _state.update {
                        it.copy(
                            metrics = event.metrics,
                            metricsByModel = it.metricsByModel + (selected.model.id to event.metrics),
                            status = "生成完成。",
                            generationRunning = false,
                        )
                    }
                    is LocalInferenceEvent.Failed -> _state.update {
                        it.copy(
                            error = event.message,
                            status = null,
                            generationRunning = false,
                        )
                    }
                }
            }
            _state.update { it.copy(generationRunning = false) }
        }
    }

    fun stopGeneration() {
        engine.cancel()
        generationJob?.cancel()
        _state.update { it.copy(status = "已停止生成。", generationRunning = false) }
    }

    fun unload() {
        if (_state.value.generationRunning) return
        viewModelScope.launch {
            engine.unload()
            _state.update { it.copy(status = "模型已卸载。", metrics = null, engineState = LocalEngineState.Uninitialized) }
        }
    }

    override fun onCleared() {
        generationJob?.cancel()
        engine.close()
        super.onCleared()
    }

    private fun setPresence(id: String, presence: ModelPresence) {
        _state.update { current ->
            current.copy(
                models = current.models.map { ui ->
                    if (ui.model.id == id) ui.copy(presence = presence) else ui
                },
            )
        }
    }

    private fun formatParams(count: Long): String =
        if (count >= 1_000_000_000L) String.format("%.2fB", count / 1_000_000_000.0)
        else String.format("%.0fM", count / 1_000_000.0)
}

private const val DEFAULT_PROMPT = "用一句话介绍你自己。"
private const val SYSTEM_PROMPT = "你是运行在 Android 设备上的中文 AI 助手，回答简洁。"
