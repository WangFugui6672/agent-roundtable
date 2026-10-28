package com.agentroundtable.app.data.knowledge

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.res.AssetManager
import com.agentroundtable.core.knowledge.EmbeddingBackend
import java.nio.LongBuffer
import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** 端侧嵌入不可用；调用方应降级为无检索，而不是让资料库功能失败。 */
class EmbeddingUnavailableException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/** 端侧嵌入的实测数据，供资料库界面展示。 */
data class EmbeddingStats(
    val modelLoadMillis: Long? = null,
    val lastInferenceMillis: Long? = null,
    val averageInferenceMillis: Long? = null,
)

/**
 * `bge-small-zh-v1.5` int8 ONNX 嵌入实现。
 *
 * 模型与词表随安装包放在 assets 中，不做运行时下载。首次 [embed] 时才创建
 * [OrtSession]，因此模型缺失或设备不支持时只在真正用到检索时失败，App 其余功能
 * 不受影响。推理在 [dispatcher] 上执行，避免阻塞主线程。
 *
 * 输出取 `last_hidden_state` 的 CLS 向量并做 L2 归一化，与 BGE 的
 * `cls` pooling + `normalize_embeddings = true` 一致。
 */
class OnnxEmbeddingBackend(
    private val assets: AssetManager,
    private val modelAssetPath: String = DEFAULT_MODEL_ASSET,
    private val vocabAssetPath: String = DEFAULT_VOCAB_ASSET,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : EmbeddingBackend {
    // 延迟到真正加载模型时再初始化，避免设备缺少 ONNX Runtime 原生库时在构造阶段崩溃。
    private val environment: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val loadMutex = Mutex()
    private val metricsLock = Any()

    private var session: OrtSession? = null
    private var tokenizer: BertTokenizer? = null
    private var loadFailure: EmbeddingUnavailableException? = null

    @Volatile
    private var modelLoadMillisValue: Long? = null

    @Volatile
    private var lastInferenceMillisValue: Long? = null

    private var inferenceCount: Int = 0
    private var totalInferenceMillis: Long = 0

    val modelLoadMillis: Long? get() = modelLoadMillisValue
    val lastInferenceMillis: Long? get() = lastInferenceMillisValue
    val averageInferenceMillis: Long?
        get() = synchronized(metricsLock) {
            if (inferenceCount == 0) null else totalInferenceMillis / inferenceCount
        }

    fun stats(): EmbeddingStats = EmbeddingStats(
        modelLoadMillis = modelLoadMillis,
        lastInferenceMillis = lastInferenceMillis,
        averageInferenceMillis = averageInferenceMillis,
    )

    override suspend fun embed(texts: List<String>): List<FloatArray> {
        if (texts.isEmpty()) return emptyList()
        return withContext(dispatcher) {
            try {
                val activeSession = ensureLoaded()
                val activeTokenizer = requireNotNull(tokenizer)
                texts.map { text -> infer(activeSession, activeTokenizer, text) }
            } catch (error: OutOfMemoryError) {
                throw EmbeddingUnavailableException(
                    "端侧嵌入推理内存不足：${error.message ?: "OutOfMemoryError"}",
                    error,
                )
            }
        }
    }

    private suspend fun ensureLoaded(): OrtSession = loadMutex.withLock {
        session?.let { return it }
        loadFailure?.let { throw it }

        val startedAt = System.nanoTime()
        try {
            val modelBytes = assets.open(modelAssetPath).use { it.readBytes() }
            val vocabulary = assets.open(vocabAssetPath).use { input ->
                input.bufferedReader(Charsets.UTF_8).readLines()
            }
            val newTokenizer = BertTokenizer(vocabulary)
            val options = OrtSession.SessionOptions().apply {
                setIntraOpNumThreads(
                    Runtime.getRuntime().availableProcessors().coerceIn(1, 4),
                )
                setInterOpNumThreads(1)
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            }
            val newSession = try {
                environment.createSession(modelBytes, options)
            } finally {
                options.close()
            }
            session = newSession
            tokenizer = newTokenizer
            modelLoadMillisValue = elapsedMillis(startedAt)
            newSession
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            throw cacheLoadFailure(error)
        } catch (error: LinkageError) {
            // 原生库缺失或 ABI 不匹配时也能降级为无检索。
            throw cacheLoadFailure(error)
        } catch (error: OutOfMemoryError) {
            // 设备内存不足时不崩溃，让资料库和圆桌其余功能继续可用。
            throw cacheLoadFailure(error)
        }
    }

    private fun cacheLoadFailure(error: Throwable): EmbeddingUnavailableException {
        val unavailable = EmbeddingUnavailableException(
            "端侧嵌入模型初始化失败：${error.message ?: error.javaClass.simpleName}",
            error,
        )
        loadFailure = unavailable
        return unavailable
    }

    private fun infer(session: OrtSession, tokenizer: BertTokenizer, text: String): FloatArray {
        val encoded = tokenizer.encode(text)
        val shape = longArrayOf(1L, encoded.length.toLong())
        val startedAt = System.nanoTime()

        val inputIds = OnnxTensor.createTensor(
            environment,
            LongBuffer.wrap(encoded.inputIds),
            shape,
        )
        val attentionMask = OnnxTensor.createTensor(
            environment,
            LongBuffer.wrap(encoded.attentionMask),
            shape,
        )
        val tokenTypeIds = OnnxTensor.createTensor(
            environment,
            LongBuffer.wrap(encoded.tokenTypeIds),
            shape,
        )

        try {
            val inputs = mutableMapOf<String, OnnxTensor>(
                "input_ids" to inputIds,
                "attention_mask" to attentionMask,
            )
            if (session.inputNames.contains(TOKEN_TYPE_IDS_INPUT)) {
                inputs[TOKEN_TYPE_IDS_INPUT] = tokenTypeIds
            }

            session.run(inputs).use { result ->
                val vector = normalize(extractClsVector(result.get(0).value))
                recordInference(elapsedMillis(startedAt))
                return vector
            }
        } finally {
            inputIds.close()
            attentionMask.close()
            tokenTypeIds.close()
        }
    }

    private fun extractClsVector(value: Any?): FloatArray {
        val batch = value as? Array<*> ?: error("模型输出不是张量")
        val first = batch.firstOrNull() ?: error("模型输出为空")
        val cls = when (first) {
            // [batch, hidden]（已导出为句向量的模型）
            is FloatArray -> first
            // [batch, sequence, hidden]（bge 的 last_hidden_state）
            is Array<*> -> first.firstOrNull() as? FloatArray ?: error("模型输出缺少 CLS 向量")
            else -> error("模型输出维度不受支持")
        }
        return cls
    }

    private fun normalize(vector: FloatArray): FloatArray {
        var squaredSum = 0.0
        for (value in vector) {
            squaredSum += value.toDouble() * value.toDouble()
        }
        val norm = sqrt(squaredSum).toFloat()
        if (norm == 0f) return vector
        return FloatArray(vector.size) { index -> vector[index] / norm }
    }

    private fun recordInference(elapsed: Long) {
        synchronized(metricsLock) {
            lastInferenceMillisValue = elapsed
            totalInferenceMillis += elapsed
            inferenceCount += 1
        }
    }

    private fun elapsedMillis(startedAt: Long): Long =
        ((System.nanoTime() - startedAt) / 1_000_000L).coerceAtLeast(0L)

    private companion object {
        const val DEFAULT_MODEL_ASSET = "models/bge-small-zh-v1.5-int8/model_int8.onnx"
        const val DEFAULT_VOCAB_ASSET = "models/bge-small-zh-v1.5-int8/vocab.txt"
        const val TOKEN_TYPE_IDS_INPUT = "token_type_ids"
    }
}
