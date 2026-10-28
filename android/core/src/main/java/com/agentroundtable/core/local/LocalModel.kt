package com.agentroundtable.core.local

/**
 * 端侧模型清单项。
 *
 * 模型文件不入库：这里只保存不可变的下载地址、体积与 SHA256。下载完成后必须校验
 * [sha256]，校验失败的文件不得进入推理。
 */
data class LocalModel(
    val id: String,
    val displayName: String,
    val quantization: String,
    val parameterLabel: String,
    val fileName: String,
    val sizeBytes: Long,
    val sha256: String,
    val downloadUrls: List<String>,
    val contextWindow: Int,
    val license: String,
    val source: String,
)

/**
 * 随包发布的模型目录。
 *
 * 首个地址指向本仓库 Release 的模型资产；该资产未发布时回退到上游 ModelScope 镜像。
 * 两个地址必须指向同一份文件，SHA256 是唯一的可信依据。
 */
object LocalModelCatalog {
    private const val RELEASE_ASSET_BASE =
        "https://github.com/WangFugui6672/agent-roundtable/releases/download/models-v1"

    private const val MODELSCOPE_BASE =
        "https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master"

    val qwen05bQ4Km = LocalModel(
        id = "qwen2.5-0.5b-instruct-q4_k_m",
        displayName = "Qwen2.5 0.5B Instruct",
        quantization = "Q4_K_M",
        parameterLabel = "0.5B",
        fileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        sizeBytes = 491_400_032L,
        sha256 = "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        downloadUrls = listOf(
            "$RELEASE_ASSET_BASE/qwen2.5-0.5b-instruct-q4_k_m.gguf",
            "$MODELSCOPE_BASE/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        ),
        contextWindow = 32_768,
        license = "Apache-2.0",
        source = "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
    )

    val qwen05bF16 = LocalModel(
        id = "qwen2.5-0.5b-instruct-fp16",
        displayName = "Qwen2.5 0.5B Instruct",
        quantization = "FP16",
        parameterLabel = "0.5B",
        fileName = "qwen2.5-0.5b-instruct-fp16.gguf",
        sizeBytes = 1_266_425_696L,
        sha256 = "8e0ae26000627ed62de0e78e41860af70094558b9d2913385c842a6aa06cf3fc",
        downloadUrls = listOf(
            "$RELEASE_ASSET_BASE/qwen2.5-0.5b-instruct-fp16.gguf",
            "$MODELSCOPE_BASE/qwen2.5-0.5b-instruct-fp16.gguf",
        ),
        contextWindow = 32_768,
        license = "Apache-2.0",
        source = "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
    )

    /** 界面默认展示的模型；量化对比使用同一模型的 FP16 版本。 */
    val all: List<LocalModel> = listOf(qwen05bQ4Km, qwen05bF16)

    fun byId(id: String): LocalModel? = all.firstOrNull { it.id == id }
}
