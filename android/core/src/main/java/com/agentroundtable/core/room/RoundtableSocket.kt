package com.agentroundtable.core.room

import kotlinx.coroutines.flow.Flow

/** 一次 WebSocket 连接上发生的事。 */
sealed interface SocketEvent {
    data object Opened : SocketEvent

    data class Text(val text: String) : SocketEvent

    data class Closed(val reason: String?) : SocketEvent

    data class Failed(val message: String?) : SocketEvent
}

/** 圆桌实时连接。实现方负责携带 `guest_session` 与 `cursor` 查询参数。 */
interface RoundtableSocket {
    val events: Flow<SocketEvent>

    /** 向服务端发送一条客户端命令；服务端会忽略不认识的命令。 */
    fun send(text: String)

    fun close()
}

/** 建立实时连接的接缝。测试用假实现，真实实现走 OkHttp。 */
fun interface RoundtableSocketFactory {
    fun open(roundtableId: String, sessionId: String, cursor: Int): RoundtableSocket
}
