package com.agentroundtable.core.room

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 把实时连接与投影串起来：连接 → 解码 → 投影 → 对外暴露状态。
 *
 * 重连与补发在后续切片补全；当前实现覆盖单次连接的生命周期。
 */
class RoomController(
    private val factory: RoundtableSocketFactory,
    private val projection: RoomProjection = RoomProjection(),
) {
    private val _view = MutableStateFlow(RoomView())
    val view: StateFlow<RoomView> = _view.asStateFlow()

    private val _connection = MutableStateFlow(ConnectionState.Closed)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()

    private var socket: RoundtableSocket? = null
    private var job: Job? = null
    private var mockRoundRequested = false

    fun connect(
        scope: CoroutineScope,
        roundtableId: String,
        sessionId: String,
        localCursor: Int? = null,
    ) {
        job?.cancel()
        socket?.close()
        _connection.value = ConnectionState.Connecting

        val active = factory.open(roundtableId, sessionId, localCursor ?: 0)
        socket = active
        job = scope.launch {
            active.events.collect { event ->
                when (event) {
                    SocketEvent.Opened -> _connection.value = ConnectionState.Connected
                    is SocketEvent.Text -> onText(event.text, localCursor)
                    is SocketEvent.Closed -> {
                        _connection.value = ConnectionState.Closed
                    }
                    is SocketEvent.Failed -> {
                        _connection.value = ConnectionState.Closed
                        _view.value = projection.snapshot().copy(diagnostic = event.message)
                    }
                }
            }
        }
    }

    private companion object {
        const val MOCK_RUN_COMMAND = """{"event_type":"mock.run"}"""
    }

    fun disconnect() {
        job?.cancel()
        job = null
        socket?.close()
        socket = null
        _connection.value = ConnectionState.Closed
    }

    private fun onText(text: String, localCursor: Int?) {
        val envelope = EventEnvelope.decode(text) ?: return
        if (envelope.eventType == EventTypes.ROOM_JOINED) {
            val payload = EventEnvelope.decodeJoined(text) ?: return
            _view.value = projection.present(payload, localCursor)
            // Mock 圆桌由客户端驱动：进入后请求服务端跑一轮确定性脚本。
            if (_view.value.isMock && !mockRoundRequested) {
                mockRoundRequested = true
                socket?.send(MOCK_RUN_COMMAND)
            }
        } else {
            projection.apply(envelope)
            _view.value = projection.snapshot()
        }
    }
}
