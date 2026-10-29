package com.agentroundtable.core.provider

/** 支持的模型服务商。均为 OpenAI 兼容接口。 */
enum class ProviderKind(val wireValue: String, val displayName: String) {
    Qwen("qwen", "通义千问"),
    DeepSeek("deepseek", "DeepSeek"),
    Custom("custom", "自定义"),
    ;

    val defaultBaseUrl: String
        get() = when (this) {
            Qwen -> "https://dashscope.aliyuncs.com/compatible-mode/v1"
            DeepSeek -> "https://api.deepseek.com/v1"
            Custom -> ""
        }

    val defaultModel: String
        get() = when (this) {
            Qwen -> "qwen-plus"
            DeepSeek -> "deepseek-chat"
            Custom -> ""
        }

    val isCustom: Boolean get() = this == Custom

    companion object {
        fun fromWire(value: String): ProviderKind? = entries.firstOrNull { it.wireValue == value }
    }
}

/**
 * 一场圆桌调用模型所需的非秘密信息。
 *
 * API Key 不属于这里：它只存在于 Keystore，或直连 Provider 的请求头中。
 */
data class ProviderConfiguration(
    val kind: ProviderKind,
    val baseUrl: String,
    val model: String,
) {
    /** 提交给服务端的元数据；永远不含密钥。 */
    fun toMetadata() = com.agentroundtable.core.model.ProviderMetadata(
        kind = kind.wireValue,
        baseUrl = baseUrl.removeSuffix("/"),
        model = model,
    )
}

/** Provider 配置的本地校验，与服务端规则保持一致。 */
sealed interface ProviderValidation {
    data object Valid : ProviderValidation

    data class Invalid(val message: String) : ProviderValidation
}

object ProviderRules {
    private val httpUrl = Regex("^https?://[^\\s?#]+$")

    fun validate(configuration: ProviderConfiguration): ProviderValidation {
        val baseUrl = configuration.baseUrl.trim()
        when {
            baseUrl.isEmpty() -> return ProviderValidation.Invalid("请填写 BaseURL。")
            !httpUrl.matches(baseUrl) ->
                return ProviderValidation.Invalid("BaseURL 必须是 http/https 地址，且不能带查询参数或片段。")
            baseUrl.split("?").size > 1 || baseUrl.split("#").size > 1 ->
                return ProviderValidation.Invalid("BaseURL 不能带查询参数或片段。")
        }
        val model = configuration.model.trim()
        if (model.isEmpty()) return ProviderValidation.Invalid("请填写模型名称。")
        if (model.length > 120) return ProviderValidation.Invalid("模型名称不能超过 120 个字符。")
        return ProviderValidation.Valid
    }

    /**
     * 修改 BaseURL 后必须重新输入密钥。
     *
     * 旧密钥属于另一个服务商，复用会把凭据发给不该收到它的地址。
     */
    fun requiresNewKey(previous: ProviderConfiguration?, next: ProviderConfiguration): Boolean {
        if (previous == null) return true
        return previous.baseUrl.removeSuffix("/") != next.baseUrl.trim().removeSuffix("/")
    }
}
