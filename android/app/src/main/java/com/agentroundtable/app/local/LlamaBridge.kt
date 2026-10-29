package com.agentroundtable.app.local

/**
 * `llama_bridge` 的 JNI 入口。
 *
 * 所有方法都返回 `null` 表示成功，返回字符串表示可直接展示的中文错误。
 * 调用方（[LlamaCppEngine]）保证同一时间只有一个线程进入原生代码。
 */
internal object LlamaBridge {
    external fun init(): String?

    external fun loadModel(path: String, contextSize: Int): String?

    external fun beginGeneration(prompt: String, maxTokens: Int): String?

    /** 返回下一个 UTF-8 文本片段；生成结束或取消时返回 null。 */
    external fun nextToken(): String?

    external fun cancelGeneration()

    external fun generatedTokenCount(): Int

    external fun modelBytes(): Long

    external fun parameterCount(): Long

    external fun systemInfo(): String

    external fun unload()

    external fun shutdown()

    fun loadLibrary(): String? = try {
        System.loadLibrary("llama_bridge")
        null
    } catch (error: UnsatisfiedLinkError) {
        error.message ?: "无法加载原生推理库。"
    }
}
