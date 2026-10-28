package com.agentroundtable.core.local

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** 推理引擎生命周期状态。界面只依赖这些状态，不依赖 llama.cpp。 */
sealed interface LocalEngineState {
    data object Uninitialized : LocalEngineState

    data object Loading : LocalEngineState

    data class Ready(
        val modelId: String,
        val modelBytes: Long,
        val parameterCount: Long,
    ) : LocalEngineState

    data class Generating(val modelId: String) : LocalEngineState

    data class Failed(val message: String) : LocalEngineState
}

/** 模型加载结果。加载耗时从调用 load 到上下文就绪为止。 */
sealed interface LocalLoadResult {
    data class Loaded(
        val loadMs: Long,
        val modelBytes: Long,
        val parameterCount: Long,
    ) : LocalLoadResult

    data class Failed(val message: String) : LocalLoadResult
}

/** 一次端侧生成的可观测指标。 */
data class LocalInferenceMetrics(
    val modelLoadMs: Long,
    val firstTokenMs: Long,
    val generatedTokens: Int,
    val decodeMs: Long,
    val peakMemoryBytes: Long,
    val modelFileBytes: Long,
) {
    /** 首 token 之后的解码速度；token 数不足时按 0 处理，避免除零。 */
    val tokensPerSecond: Double
        get() = if (decodeMs <= 0L || generatedTokens <= 1) 0.0 else {
            (generatedTokens - 1) * 1000.0 / decodeMs
        }
}

/** 流式生成事件。 */
sealed interface LocalInferenceEvent {
    data class Token(val text: String) : LocalInferenceEvent

    data class Completed(val metrics: LocalInferenceMetrics) : LocalInferenceEvent

    data class Failed(val message: String) : LocalInferenceEvent
}

/**
 * 端侧推理接缝。
 *
 * UI 与 ViewModel 只依赖本接口；实现放在 `:app`，因此替换推理框架不会影响界面层。
 */
interface LocalInferenceEngine {
    val state: StateFlow<LocalEngineState>

    /** 加载模型。实现应保证同一时间只有一个模型处于加载/生成状态。 */
    suspend fun load(model: LocalModel, path: String): LocalLoadResult

    /** 生成文本。Flow 收集完成时发出 [LocalInferenceEvent.Completed]。 */
    fun generate(prompt: String, maxTokens: Int = DEFAULT_MAX_TOKENS): Flow<LocalInferenceEvent>

    /** 请求停止当前生成；下一次原生 token 循环会退出。 */
    fun cancel()

    /** 卸载模型并释放原生资源。 */
    suspend fun unload()

    /** 释放引擎；之后不可再使用。 */
    fun close()

    companion object {
        const val DEFAULT_MAX_TOKENS = 128
    }
}

/** 端侧 prompt 使用 Qwen 的 ChatML 模板，格式在纯 JVM 上可测。 */
object LocalPrompt {
    fun qwenChatMl(system: String, user: String): String = buildString {
        append("<|im_start|>system\n")
        append(system.trim())
        append("<|im_end|>\n")
        append("<|im_start|>user\n")
        append(user.trim())
        append("<|im_end|>\n")
        append("<|im_start|>assistant\n")
    }
}
