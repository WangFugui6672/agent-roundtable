package com.agentroundtable.app.data

import android.content.Context
import androidx.core.content.edit
import com.agentroundtable.core.session.GuestSessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 匿名会话标识的本地存储。
 *
 * 文件位于应用私有目录，不可被其他应用读取，也随卸载一并删除。
 * API Key 不走这里，它只存在于 Android Keystore。
 */
class PreferencesGuestSessionStore(context: Context) : GuestSessionStore {
    private val preferences =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override suspend fun read(): String? = withContext(Dispatchers.IO) {
        preferences.getString(KEY_SESSION_ID, null)
    }

    override suspend fun write(sessionId: String) = withContext(Dispatchers.IO) {
        preferences.edit { putString(KEY_SESSION_ID, sessionId) }
    }

    private companion object {
        const val PREFERENCES_NAME = "guest_session"
        const val KEY_SESSION_ID = "session_id"
    }
}
