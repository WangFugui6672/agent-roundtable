package com.agentroundtable.app.data.provider

import android.content.Context
import androidx.core.content.edit
import com.agentroundtable.core.provider.NoticeStore
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderConfigurationStorage
import com.agentroundtable.core.provider.ProviderKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 非秘密 Provider 配置的本地存储。其中不得出现 API Key。 */
class PreferencesProviderStorage(context: Context) : ProviderConfigurationStorage {
    private val preferences =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override suspend fun read(): ProviderConfiguration? = withContext(Dispatchers.IO) {
        val kind = preferences.getString(KEY_KIND, null) ?: return@withContext null
        val providerKind = ProviderKind.fromWire(kind) ?: return@withContext null
        ProviderConfiguration(
            kind = providerKind,
            baseUrl = preferences.getString(KEY_BASE_URL, "").orEmpty(),
            model = preferences.getString(KEY_MODEL, "").orEmpty(),
        )
    }

    override suspend fun write(configuration: ProviderConfiguration) = withContext(Dispatchers.IO) {
        preferences.edit {
            putString(KEY_KIND, configuration.kind.wireValue)
            putString(KEY_BASE_URL, configuration.baseUrl)
            putString(KEY_MODEL, configuration.model)
        }
    }

    override suspend fun clear() = withContext(Dispatchers.IO) {
        preferences.edit { clear() }
    }

    private companion object {
        const val PREFERENCES_NAME = "provider_configuration"
        const val KEY_KIND = "kind"
        const val KEY_BASE_URL = "base_url"
        const val KEY_MODEL = "model"
    }
}

/** 第三方数据提示的确认状态。 */
class PreferencesNoticeStore(context: Context) : NoticeStore {
    private val preferences =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override suspend fun isAcknowledged(): Boolean = withContext(Dispatchers.IO) {
        preferences.getBoolean(KEY_ACKNOWLEDGED, false)
    }

    override suspend fun acknowledge() = withContext(Dispatchers.IO) {
        preferences.edit { putBoolean(KEY_ACKNOWLEDGED, true) }
    }

    private companion object {
        const val PREFERENCES_NAME = "third_party_notice"
        const val KEY_ACKNOWLEDGED = "acknowledged"
    }
}
