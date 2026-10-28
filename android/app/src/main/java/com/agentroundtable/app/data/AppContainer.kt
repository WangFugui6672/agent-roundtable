package com.agentroundtable.app.data

import android.content.Context
import com.agentroundtable.app.BuildConfig
import androidx.room.Room
import com.agentroundtable.app.data.cache.RoomCacheRepository
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

    val socketFactory: OkHttpSocketFactory by lazy {
        OkHttpSocketFactory(baseUrl = BuildConfig.BACKEND_BASE_URL)
    }
}
