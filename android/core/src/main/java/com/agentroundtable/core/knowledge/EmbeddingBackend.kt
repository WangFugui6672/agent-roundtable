package com.agentroundtable.core.knowledge

/** `bge-small-zh-v1.5` int8 量化模型的固定输出维度。 */
const val EMBEDDING_DIMENSION = 512

/**
 * 嵌入后端接缝。
 *
 * 输入一批文本，返回与输入顺序一一对应的向量；每个向量的维度固定为
 * [EMBEDDING_DIMENSION]。实现位于 `:app`（ONNX Runtime），`:core` 只依赖这个接口，
 * 单元测试使用可预测的假实现，不加载真实模型文件。
 *
 * 模型缺失、初始化失败或推理异常时抛出异常，由调用方决定是否降级为无检索。
 */
interface EmbeddingBackend {
    suspend fun embed(texts: List<String>): List<FloatArray>
}
