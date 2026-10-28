package com.agentroundtable.app.data

import android.content.Context
import com.agentroundtable.app.BuildConfig
import androidx.room.Room
import com.agentroundtable.app.data.cache.RoomCacheRepository
import com.agentroundtable.app.data.knowledge.AndroidDocumentParser
import com.agentroundtable.app.data.knowledge.ContentResolverDocumentSourceReader
import com.agentroundtable.app.data.knowledge.DocumentSourceReader
import com.agentroundtable.app.data.knowledge.KnowledgeDatabase
import com.agentroundtable.app.data.knowledge.RoomDocumentStore
import com.agentroundtable.app.data.provider.KeystoreSecretStore
import com.agentroundtable.app.data.provider.PreferencesNoticeStore
import com.agentroundtable.app.data.provider.PreferencesProviderStorage
import com.agentroundtable.core.knowledge.DocumentParser
import com.agentroundtable.core.knowledge.DocumentStore
import com.agentroundtable.core.knowledge.KnowledgeBase
import com.agentroundtable.core.provider.ProviderProbe
import com.agentroundtable.core.turn.ProviderChatClient
import com.agentroundtable.core.turn.TurnRunner
import com.agentroundtable.core.provider.ProviderSettings
import com.agentroundtable.core.summary.RoundSummaryGenerator
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

    private val knowledgeDatabase: KnowledgeDatabase by lazy {
        Room.databaseBuilder(applicationContext, KnowledgeDatabase::class.java, "knowledge.db")
            .build()
    }

    /** 资料库存储；#32 的检索直接复用这个接缝。 */
    val documentStore: DocumentStore by lazy { RoomDocumentStore(knowledgeDatabase) }

    private val documentParser: DocumentParser by lazy {
        AndroidDocumentParser(applicationContext)
    }

    val knowledgeBase: KnowledgeBase by lazy {
        KnowledgeBase(parser = documentParser, store = documentStore)
    }

    val documentSourceReader: DocumentSourceReader by lazy {
        ContentResolverDocumentSourceReader(applicationContext)
    }

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

    val summaryGenerator: RoundSummaryGenerator by lazy {
        RoundSummaryGenerator(apiClient, chatClient)
    }

    val socketFactory: OkHttpSocketFactory by lazy {
        OkHttpSocketFactory(baseUrl = BuildConfig.BACKEND_BASE_URL)
    }
}
