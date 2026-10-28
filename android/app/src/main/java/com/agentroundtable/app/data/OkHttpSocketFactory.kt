package com.agentroundtable.app.data

import com.agentroundtable.core.room.RoundtableSocket
import com.agentroundtable.core.room.RoundtableSocketFactory
import com.agentroundtable.core.room.SocketEvent
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** 用 OkHttp 建立圆桌的实时连接。 */
class OkHttpSocketFactory(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
) : RoundtableSocketFactory {
    override fun open(roundtableId: String, sessionId: String, cursor: Int): RoundtableSocket {
        val url = buildString {
            append(baseUrl.replaceFirst("https", "wss").replaceFirst("http", "ws"))
            append("/ws/v1/roundtables/")
            append(roundtableId)
            append("/?guest_session=")
            append(sessionId)
            append("&cursor=")
            append(cursor)
        }
        return OkHttpRoundtableSocket(client, Request.Builder().url(url).build())
    }
}

private class OkHttpRoundtableSocket(
    client: OkHttpClient,
    request: Request,
) : RoundtableSocket {
    private val channel = Channel<SocketEvent>(capacity = Channel.UNLIMITED)

    override val events: Flow<SocketEvent> = channel.receiveAsFlow()

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            channel.trySend(SocketEvent.Opened)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            channel.trySend(SocketEvent.Text(text))
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            channel.trySend(SocketEvent.Closed(reason.ifBlank { null }))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            channel.trySend(SocketEvent.Closed(reason.ifBlank { null }))
            channel.close()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            channel.trySend(SocketEvent.Failed(t.message))
            channel.close()
        }
    }

    private val webSocket: WebSocket = client.newWebSocket(request, listener)

    override fun send(text: String) {
        webSocket.send(text)
    }

    override fun close() {
        webSocket.close(NORMAL_CLOSURE, null)
        channel.close()
    }

    private companion object {
        const val NORMAL_CLOSURE = 1000
    }
}
