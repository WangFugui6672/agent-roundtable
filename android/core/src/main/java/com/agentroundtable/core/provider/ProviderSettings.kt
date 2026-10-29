package com.agentroundtable.core.provider

/**
 * 密钥存储接缝。
 *
 * 真实实现走 Android Keystore；测试使用内存实现，不依赖真实密钥库。
 */
interface SecretStore {
    suspend fun read(name: String): String?

    suspend fun write(name: String, value: String)

    suspend fun delete(name: String)
}

/** 非秘密 Provider 配置的本地存储接缝。 */
interface ProviderConfigurationStorage {
    suspend fun read(): ProviderConfiguration?

    suspend fun write(configuration: ProviderConfiguration)

    suspend fun clear()
}

/** 第三方数据提示的确认状态。 */
interface NoticeStore {
    suspend fun isAcknowledged(): Boolean

    suspend fun acknowledge()
}

/** 设置页需要展示的 Provider 状态。 */
data class ProviderState(
    val configuration: ProviderConfiguration? = null,
    val hasKey: Boolean = false,
    val noticeAcknowledged: Boolean = false,
) {
    /** 配置不完整时必须提示用户，不允许静默降级为 Mock。 */
    val isComplete: Boolean
        get() = configuration != null && hasKey && configuration.baseUrl.isNotBlank() &&
            configuration.model.isNotBlank()
}

sealed interface ProviderSaveResult {
    data object Saved : ProviderSaveResult

    data class Invalid(val message: String) : ProviderSaveResult

    /** 换了 BaseURL 却没给新密钥。 */
    data class KeyRequired(val message: String) : ProviderSaveResult
}

/**
 * Provider 配置的读写与规则。
 *
 * 密钥与非秘密配置分开存放：配置可以随意读写，密钥只经由 [SecretStore]。
 */
class ProviderSettings(
    private val storage: ProviderConfigurationStorage,
    private val secrets: SecretStore,
    private val notices: NoticeStore,
) {
    suspend fun load(): ProviderState = ProviderState(
        configuration = storage.read(),
        hasKey = !secrets.read(API_KEY_NAME).isNullOrBlank(),
        noticeAcknowledged = notices.isAcknowledged(),
    )

    /**
     * 保存配置与密钥。
     *
     * 修改 BaseURL 时必须提供新密钥：旧密钥属于另一个服务商。
     */
    suspend fun save(
        configuration: ProviderConfiguration,
        apiKey: String?,
    ): ProviderSaveResult {
        when (val validation = ProviderRules.validate(configuration)) {
            is ProviderValidation.Invalid -> return ProviderSaveResult.Invalid(validation.message)
            ProviderValidation.Valid -> Unit
        }

        val previous = storage.read()
        val trimmedKey = apiKey?.trim().orEmpty()
        val needNewKey = ProviderRules.requiresNewKey(previous, configuration)

        if (needNewKey && trimmedKey.isEmpty()) {
            return ProviderSaveResult.KeyRequired("修改 BaseURL 后需要重新输入 API Key。")
        }
        if (!needNewKey && trimmedKey.isEmpty() && secrets.read(API_KEY_NAME).isNullOrBlank()) {
            return ProviderSaveResult.KeyRequired("请填写 API Key。")
        }

        storage.write(configuration.copy(baseUrl = configuration.baseUrl.trim().removeSuffix("/")))
        if (trimmedKey.isNotEmpty()) {
            secrets.write(API_KEY_NAME, trimmedKey)
        }
        return ProviderSaveResult.Saved
    }

    /** 删除 Provider 时同时删除密钥，不留孤立凭据。 */
    suspend fun delete() {
        storage.clear()
        secrets.delete(API_KEY_NAME)
    }

    suspend fun acknowledgeNotice() = notices.acknowledge()

    suspend fun apiKey(): String? = secrets.read(API_KEY_NAME)

    companion object {
        const val API_KEY_NAME = "provider_api_key"
    }
}
