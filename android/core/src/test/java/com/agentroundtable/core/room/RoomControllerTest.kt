package com.agentroundtable.core.room

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeSocket : RoundtableSocket {
    private val channel = Channel<SocketEvent>(capacity = Channel.UNLIMITED)
    val sent = mutableListOf<String>()
    var closed = false

    override val events = channel.receiveAsFlow()

    override fun send(text: String) {
        sent += text
    }

    override fun close() {
        closed = true
    }

    fun emit(event: SocketEvent) {
        channel.trySend(event)
    }
}

class RoomControllerTest {
    @Test
    fun `joining a mock roundtable asks the server to run the mock script once`() = runTest(UnconfinedTestDispatcher()) {
        val socket = FakeSocket()
        val controller = RoomController({ _, _, _ -> socket })
        controller.connect(backgroundScope, "c0de", "session")

        socket.emit(SocketEvent.Opened)
        socket.emit(SocketEvent.Text(JOINED_MOCK))
        socket.emit(SocketEvent.Text(JOINED_MOCK))

        assertEquals(ConnectionState.Connected, controller.connection.value)
        assertEquals(listOf("""{"event_type":"mock.run"}"""), socket.sent)
        assertEquals("c0de", controller.view.value.roundtableId)
    }

    @Test
    fun `a roundtable with a provider does not request a mock run`() = runTest(UnconfinedTestDispatcher()) {
        val socket = FakeSocket()
        val controller = RoomController({ _, _, _ -> socket })
        controller.connect(backgroundScope, "c0de", "session")

        socket.emit(SocketEvent.Text(JOINED_REAL))

        assertTrue(socket.sent.isEmpty())
        assertEquals(false, controller.view.value.isMock)
    }

    @Test
    fun `events after join update the view`() = runTest(UnconfinedTestDispatcher()) {
        val socket = FakeSocket()
        val controller = RoomController({ _, _, _ -> socket })
        controller.connect(backgroundScope, "c0de", "session")
        socket.emit(SocketEvent.Text(JOINED_MOCK))
        socket.emit(
            SocketEvent.Text(
                """{"event_id":"e2","room_id":"c0de","sequence":2,"created_at":"2026-10-26T01:02:03.456Z",
                    "event_type":"agent.thinking","payload":{"round":1,"agent_id":"p1","agent_name":"方案派"}}""",
            ),
        )

        assertEquals(2, controller.view.value.lastSequence)
        val notices = controller.view.value.entries.filterIsInstance<RoomEntry.Notice>()
        assertEquals(NoticeKind.Thinking, notices.single().kind)
    }

    @Test
    fun `disconnect closes the socket`() = runTest(UnconfinedTestDispatcher()) {
        val socket = FakeSocket()
        val controller = RoomController({ _, _, _ -> socket })
        controller.connect(backgroundScope, "c0de", "session")

        controller.disconnect()

        assertTrue(socket.closed)
        assertEquals(ConnectionState.Closed, controller.connection.value)
    }

    private companion object {
        const val PARTICIPANTS = """
            [{"id":"p1","position":0,"state":"waiting","agent":{"id":"a1","key":"advocate","name":"方案派",
              "tagline":"t","expertise":"e","goal":"g","default_stance":"d","style":"s"}}]
        """

        val JOINED_MOCK = """
            {"event_id":"joined","room_id":"c0de","sequence":0,"created_at":"2026-10-26T01:02:03.456Z",
             "event_type":"room.joined","payload":{"roundtable":{"id":"c0de","topic":"议题","status":"ready",
             "current_round":0,"max_rounds":2,"last_sequence":0,"provider":null,
             "participants":$PARTICIPANTS},"messages":[],"failures":[],"summary":null,
             "replay":{"requested_cursor":null,"oldest_sequence":null,"latest_sequence":0,
                       "window_days":90,"cursor_expired":false}}}
        """.trimIndent()

        val JOINED_REAL = JOINED_MOCK.replace(
            """"provider":null""",
            """"provider":{"kind":"deepseek","base_url":"https://api.deepseek.com/v1","model":"deepseek-chat"}""",
        )
    }
}
