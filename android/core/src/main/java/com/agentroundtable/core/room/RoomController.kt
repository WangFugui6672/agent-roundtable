package com.agentroundtable.core.room

import com.agentroundtable.core.summary.RoundSummaryResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 把实时连接、投影与本地缓存串起来。
 *
 * 断线后按退避重新连接并携带最后已处理游标；每次状态变化都写回缓存，
 * 因此进程被终止后再次打开仍能回到原来的现场。
 */
class RoomController(
    private val factory: RoundtableSocketFactory,
    private val cache: RoomCache? = null,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val reconnectDelaysMs: List<Long> = listOf(500, 1_000, 2_000, 4_000, 8_000),
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
    ) {
        disconnect()
        job = scope.launch {
            restoreFromCache(roundtableId)

            var attempt = 0
            while (currentCoroutineContext().isActive) {
                _connection.value = if (attempt == 0) {
                    ConnectionState.Connecting
                } else {
                    ConnectionState.Reconnecting
                }

                val active = factory.open(
                    roundtableId,
                    sessionId,
                    projection.snapshot().lastSequence,
                )
                socket = active
                var opened = false

                active.events.collect { event ->
                    when (event) {
                        SocketEvent.Opened -> {
                            opened = true
                            attempt = 0
                            _connection.value = ConnectionState.Connected
                        }

                        is SocketEvent.Text -> onText(event.text, tryMockRun = true)

                        is SocketEvent.Closed -> Unit

                        is SocketEvent.Failed -> {
                            _view.value = projection.snapshot().copy(diagnostic = event.message)
                        }
                    }
                }

                socket = null
                _connection.value = ConnectionState.Reconnecting
                attempt = if (opened) 1 else (attempt + 1).coerceAtMost(reconnectDelaysMs.lastIndex)
                delay(reconnectDelaysMs[attempt.coerceIn(0, reconnectDelaysMs.lastIndex)])
            }
        }
    }

    fun disconnect() {
        job?.cancel()
        job = null
        socket?.close()
        socket = null
        mockRoundRequested = false
        _connection.value = ConnectionState.Closed
    }

    private suspend fun restoreFromCache(roundtableId: String) {
        val stored = cache?.load(roundtableId) ?: return
        projection.restore(stored)
        _view.value = projection.snapshot()
    }

    /**
     * 把控制命令响应里带回的事件并入投影。
     *
     * 这些事件通常也会经 WebSocket 到达，投影按事件 ID 去重，因此重复并入是安全的；
     * 连接中断时它们还能保证界面状态正确。
     */
    suspend fun applyEvents(envelopes: List<EventEnvelope>) {
        if (envelopes.isEmpty()) return
        var changed = false
        envelopes.forEach { envelope ->
            if (envelope.eventType == EventTypes.ROOM_JOINED) return@forEach
            if (projection.apply(envelope)) changed = true
        }
        if (changed) {
            _view.value = projection.snapshot()
            persist()
        }
    }

    /**
     * 合并一次结论提交响应。
     *
     * 幂等重试可能不返回事件，所以响应里的结论和圆桌快照也必须并入投影。
     */
    suspend fun applySummaryResponse(response: RoundSummaryResponse) {
        var changed = projection.applySummary(
            summary = response.summary,
            status = response.roundtable.status,
            currentRound = response.roundtable.currentRound,
        )
        response.events.forEach { envelope ->
            if (envelope.eventType == EventTypes.ROOM_JOINED) return@forEach
            if (projection.apply(envelope)) changed = true
        }
        if (changed) {
            _view.value = projection.snapshot()
            persist()
        }
    }

    private suspend fun onText(text: String, tryMockRun: Boolean) {
        val envelope = EventEnvelope.decode(text) ?: return
        if (envelope.eventType == EventTypes.ROOM_JOINED) {
            val payload = EventEnvelope.decodeJoined(text) ?: return
            _view.value = projection.present(payload, localCursor = projection.snapshot().lastSequence)
            if (tryMockRun && _view.value.isMock && !mockRoundRequested) {
                mockRoundRequested = true
                socket?.send(MOCK_RUN_COMMAND)
            }
        } else {
            projection.apply(envelope)
            _view.value = projection.snapshot()
        }
        persist()
    }

    /** 写回缓存。事件按序处理，因此缓存也按序落盘，不会出现游标回退。 */
    private suspend fun persist() {
        val store = cache ?: return
        val snapshot = _view.value
        if (snapshot.roundtableId.isBlank()) return
        store.save(snapshot.toStoredRoom(clock()))
    }

    private companion object {
        const val MOCK_RUN_COMMAND = """{"event_type":"mock.run"}"""
    }
}
