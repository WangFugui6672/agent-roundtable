package com.agentroundtable.app.data

import android.content.Context
import com.agentroundtable.app.BuildConfig
import androidx.room.Room
import com.agentroundtable.app.data.cache.RoomCacheRepository
import com.agentroundtable.app.data.provider.KeystoreSecretStore
import com.agentroundtable.app.data.provider.PreferencesNoticeStore
import com.agentroundtable.app.data.provider.PreferencesProviderStorage
import com.agentroundtable.app.local.AndroidDeviceMemoryProbe
import com.agentroundtable.app.local.AndroidLocalModelStore
import com.agentroundtable.app.local.DeviceMemoryProbe
import com.agentroundtable.app.local.LlamaCppEngine
import com.agentroundtable.app.local.LocalModelStore
import com.agentroundtable.core.local.LocalInferenceEngine
import com.agentroundtable.core.provider.ProviderProbe
import com.agentroundtable.core.turn.ProviderChatClient
import com.agentroundtable.core.turn.TurnRunner
import com.agentroundtable.core.provider.ProviderSettings
import com.agentroundtable.app.data.cache.RoundtableDatabase
import com.agentroundtable.core.HomeRepository
import com.agentroundtable.core.api.ApiClient

/**
 * 手写依赖容器。
 *
 * 项目只有两个模块、依赖关系是线性的，使用显式构造注入比引入注解处理器更容易追踪，
 * 也让 `:core` 保持在纯 JVM 上可测。
 */
class AppContainer(context: Context) {
    private val applicationContext = context.applicationContext

    val apiClient: ApiClient by lazy {
        ApiClient(
            baseUrl = BuildConfig.BACKEND_BASE_URL,
            transport = OkHttpTransport(),
        )
    }

    val guestSessionStore: com.agentroundtable.core.session.GuestSessionStore by lazy {
        PreferencesGuestSessionStore(applicationContext)
    }

    val homeRepository: HomeRepository by lazy {
        HomeRepository(api = apiClient, sessions = guestSessionStore)
    }

    private val database: RoundtableDatabase by lazy {
        Room.databaseBuilder(applicationContext, RoundtableDatabase::class.java, "roundtable.db")
            .build()
    }

    val roomCache: RoomCacheRepository by lazy { RoomCacheRepository(database) }

    private val providerStorage: PreferencesProviderStorage by lazy {
        PreferencesProviderStorage(applicationContext)
    }

    private val providerSecrets: KeystoreSecretStore by lazy {
        KeystoreSecretStore(applicationContext)
    }

    val providerSettings: ProviderSettings by lazy {
        ProviderSettings(
            storage = providerStorage,
            secrets = providerSecrets,
            notices = PreferencesNoticeStore(applicationContext),
        )
    }

    val providerProbe: ProviderProbe by lazy { ProviderProbe(OkHttpTransport()) }

    val chatClient: ProviderChatClient by lazy { ProviderChatClient(OkHttpStreamSource()) }

    val turnRunner: TurnRunner by lazy { TurnRunner(apiClient, chatClient) }

    val socketFactory: OkHttpSocketFactory by lazy {
        OkHttpSocketFactory(baseUrl = BuildConfig.BACKEND_BASE_URL)
    }

    val localModelStore: LocalModelStore by lazy {
        AndroidLocalModelStore(applicationContext)
    }

    val deviceMemory: DeviceMemoryProbe by lazy {
        AndroidDeviceMemoryProbe(applicationContext)
    }

    /** 端侧引擎与云端 Provider 完全独立；本地失败不会影响圆桌讨论。 */
    val localInferenceEngine: LocalInferenceEngine by lazy {
        LlamaCppEngine(peakMemoryBytes = { deviceMemory.peakMemoryBytes() })
    }
}
