package com.agentroundtable.core.session

/**
 * 匿名会话标识的本地存储接缝。
 *
 * 匿名会话 UUID 即能力凭据，真实实现必须保存在受保护的位置，不得写入普通偏好设置之外的可见存储。
 */
interface GuestSessionStore {
    suspend fun read(): String?

    suspend fun write(sessionId: String)
}
