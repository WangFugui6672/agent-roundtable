package com.agentroundtable.app.local

import android.os.SystemClock
import com.agentroundtable.core.local.LocalEngineState
import com.agentroundtable.core.local.LocalInferenceEngine
import com.agentroundtable.core.local.LocalInferenceEvent
import com.agentroundtable.core.local.LocalInferenceMetrics
import com.agentroundtable.core.local.LocalLoadResult
import com.agentroundtable.core.local.LocalModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 基于 llama.cpp 的端侧推理实现。
 *
 * 原生库只在首次加载模型时初始化。所有原生调用都串行在一个单线程调度器上，
 * 避免 llama_context 被并发访问。
 */
class LlamaCppEngine(
    private val peakMemoryBytes: () -> Long,
) : LocalInferenceEngine {
    private val _state = MutableStateFlow<LocalEngineState>(LocalEngineState.Uninitialized)
    override val state: StateFlow<LocalEngineState> = _state.asStateFlow()

    @OptIn(ExperimentalCoroutinesApi::class)
    private val dispatcher = Dispatchers.IO.limitedParallelism(1)

    private var libraryError: String? = null
    private var libraryLoaded = false
    private var loadedModel: LocalModel? = null
    private var loadDurationMs = 0L
    private var parameterCount = 0L

    override suspend fun load(model: LocalModel, path: String): LocalLoadResult =
        withContext(dispatcher) {
            val file = File(path)
            if (!file.isFile || !file.canRead()) {
                return@withContext fail("模型文件不可读：$path")
            }
            _state.value = LocalEngineState.Loading
            if (!ensureLibrary()) {
                return@withContext fail("原生推理库不可用：${libraryError ?: "未知原因"}")
            }
            val started = SystemClock.elapsedRealtime()
            LlamaBridge.loadModel(path, CONTEXT_SIZE)?.let { message ->
                return@withContext fail(message)
            }
            loadDurationMs = SystemClock.elapsedRealtime() - started
            loadedModel = model
            parameterCount = LlamaBridge.parameterCount()
            val loadResult = LocalLoadResult.Loaded(
                loadMs = loadDurationMs,
                modelBytes = LlamaBridge.modelBytes(),
                parameterCount = parameterCount,
            )
            _state.value = LocalEngineState.Ready(
                modelId = model.id,
                modelBytes = loadResult.modelBytes,
                parameterCount = loadResult.parameterCount,
            )
            loadResult
        }

    override fun generate(prompt: String, maxTokens: Int): Flow<LocalInferenceEvent> = flow {
        val model = loadedModel
        if (model == null || _state.value !is LocalEngineState.Ready) {
            emit(LocalInferenceEvent.Failed("请先加载模型。"))
            return@flow
        }
        if (prompt.isBlank()) {
            emit(LocalInferenceEvent.Failed("请输入要生成的内容。"))
            return@flow
        }

        _state.value = LocalEngineState.Generating(model.id)
        val started = SystemClock.elapsedRealtime()
        LlamaBridge.beginGeneration(prompt, maxTokens)?.let { message ->
            _state.value = LocalEngineState.Ready(model.id, model.sizeBytes, parameterCount)
            emit(LocalInferenceEvent.Failed(message))
            return@flow
        }

        var firstTokenAt: Long? = null
        try {
            while (currentCoroutineContext().isActive) {
                val piece = LlamaBridge.nextToken() ?: break
                if (piece.isNotEmpty()) {
                    if (firstTokenAt == null) firstTokenAt = SystemClock.elapsedRealtime()
                    emit(LocalInferenceEvent.Token(piece))
                }
            }
        } catch (cancelled: CancellationException) {
            LlamaBridge.cancelGeneration()
            _state.value = LocalEngineState.Ready(model.id, model.sizeBytes, parameterCount)
            throw cancelled
        } catch (error: Throwable) {
            _state.value = LocalEngineState.Failed(error.message ?: "端侧生成失败。")
            emit(LocalInferenceEvent.Failed(error.message ?: "端侧生成失败。"))
            return@flow
        }

        val finished = SystemClock.elapsedRealtime()
        val metrics = LocalInferenceMetrics(
            modelLoadMs = loadDurationMs,
            firstTokenMs = firstTokenAt?.let { it - started } ?: 0L,
            generatedTokens = LlamaBridge.generatedTokenCount(),
            decodeMs = firstTokenAt?.let { finished - it } ?: 0L,
            peakMemoryBytes = peakMemoryBytes(),
            modelFileBytes = model.sizeBytes,
        )
        _state.value = LocalEngineState.Ready(model.id, model.sizeBytes, parameterCount)
        emit(LocalInferenceEvent.Completed(metrics))
    }.flowOn(dispatcher)

    override fun cancel() {
        if (libraryLoaded) LlamaBridge.cancelGeneration()
    }

    override suspend fun unload() = withContext(dispatcher) {
        if (libraryLoaded) LlamaBridge.unload()
        loadedModel = null
        loadDurationMs = 0
        parameterCount = 0
        _state.value = LocalEngineState.Uninitialized
    }

    override fun close() {
        if (libraryLoaded) {
            LlamaBridge.cancelGeneration()
            LlamaBridge.shutdown()
            libraryLoaded = false
        }
        loadedModel = null
        _state.value = LocalEngineState.Uninitialized
    }

    private suspend fun ensureLibrary(): Boolean {
        if (libraryLoaded) return true
        libraryError = LlamaBridge.loadLibrary()
        if (libraryError == null) {
            libraryError = LlamaBridge.init()
        }
        libraryLoaded = libraryError == null
        return libraryLoaded
    }

    private fun fail(message: String): LocalLoadResult.Failed {
        _state.value = LocalEngineState.Failed(message)
        return LocalLoadResult.Failed(message)
    }

    private companion object {
        /** 2K 上下文足以覆盖单轮对话，并给 2 GB 模拟器留出 KV cache 余量。 */
        const val CONTEXT_SIZE = 2048
    }
}
