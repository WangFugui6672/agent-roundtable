package com.agentroundtable.app.ui.room

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.api.HttpResponse
import com.agentroundtable.core.api.HttpTransport
import com.agentroundtable.core.model.RoundSummary
import com.agentroundtable.core.model.SummaryItem
import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.core.room.RoundtableSocket
import com.agentroundtable.core.room.SocketEvent
import com.agentroundtable.core.room.StoredRoom
import com.agentroundtable.core.summary.RoundSummaryGenerator
import com.agentroundtable.core.turn.ProviderChatClient
import com.agentroundtable.core.turn.StreamSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class FakeSocket : RoundtableSocket {
    private val channel = Channel<SocketEvent>(capacity = Channel.UNLIMITED)
    override val events = channel.receiveAsFlow()
    var closed = false

    override fun send(text: String) = Unit

    override fun close() {
        closed = true
    }

    fun emit(event: SocketEvent) {
        channel.trySend(event)
    }
}

private class MemoryRoomCache : RoomCache {
    var stored: StoredRoom? = null

    override suspend fun load(roundtableId: String): StoredRoom? =
        stored?.takeIf { it.roundtableId == roundtableId }

    override suspend fun save(room: StoredRoom) {
        stored = room
    }

    override suspend fun list(): List<StoredRoom> = listOfNotNull(stored)

    override suspend fun delete(roundtableId: String) {
        stored = null
    }

    override suspend fun isDeleted(roundtableId: String): Boolean = false
}

private class SummaryTransport(private val response: String) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()

    override suspend fun execute(request: HttpRequest): HttpResponse {
        requests += request
        return HttpResponse(201, response)
    }
}

class RoomSummaryViewModelTest {
    private val dispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `a summarizing room automatically generates a degraded summary and caches it`() =
        runTest(dispatcher) {
            val socket = FakeSocket()
            val cache = MemoryRoomCache()
            val transport = SummaryTransport(SUMMARY_RESPONSE)
            val api = ApiClient("http://backend.test", transport)
            val controller = RoomController({ _, _, _ -> socket }, cache = cache)
            val viewModel = RoomViewModel(
                roundtableId = "room",
                controller = controller,
                api = api,
                cache = cache,
                sessionProvider = { "session" },
                summaryGenerator = RoundSummaryGenerator(
                    api,
                    ProviderChatClient(StreamSource { error("没有 Provider 时不应调用模型") }),
                    retryDelayMs = 0,
                ),
            )

            socket.emit(
                SocketEvent.Text(
                    """{"event_id":"joined","room_id":"room","sequence":0,
                        "created_at":"2026-10-26T01:02:03.456Z","event_type":"room.joined",
                        "payload":{"roundtable":{"id":"room","topic":"议题","status":"summarizing",
                          "current_round":2,"max_rounds":2,"last_sequence":5,
                          "provider":{"kind":"deepseek","base_url":"https://api.deepseek.com/v1",
                            "model":"deepseek-chat"},
                          "participants":[{"id":"p1","position":0,"state":"completed",
                            "agent":{"id":"a1","key":"advocate","name":"方案派","tagline":"t",
                              "expertise":"e","goal":"g","default_stance":"d","style":"s"}}]},
                          "messages":[{"id":"m1","turn_id":"t1","round_number":2,
                            "author":{"type":"agent","roundtable_agent_id":"p1",
                              "agent_key":"advocate","name":"方案派"},
                            "message_type":"support","claim":"先做实验","body":"支持先做实验",
                            "stance":"support","references":[],"challenge_target_agent_id":null,
                            "confidence":0.8,"is_key_point":false,"supersedes_message_id":null,
                            "superseded_by_message_id":null,
                            "created_at":"2026-10-26T01:03:03.456Z"}],
                          "summary":null,
                          "replay":{"requested_cursor":0,"oldest_sequence":null,
                            "latest_sequence":5,"window_days":90,"cursor_expired":false}}}
                    """.trimIndent(),
                ),
            )
            advanceUntilIdle()

            val view = viewModel.view.value
            assertEquals("completed", view.status)
            assertNotNull(view.summary)
            assertEquals(1, view.summary?.version)
            assertTrue(view.summary?.degraded == true)
            assertEquals("m1", view.summary?.consensus?.single()?.referenceMessageIds?.single())

            val submission = transport.requests.single { it.url.endsWith("/summary") }
            assertTrue(submission.body.orEmpty().contains("\"expected_version\":0"))
            assertTrue(submission.body.orEmpty().contains("\"degraded\":true"))
            assertNotNull(cache.stored?.summary)

            controller.disconnect()
        }

    @Test
    fun `a cached summary is restored on restart without regenerating`() = runTest(dispatcher) {
        val socket = FakeSocket()
        val cache = MemoryRoomCache().apply {
            stored = StoredRoom(
                roundtableId = "room",
                topic = "议题",
                status = "completed",
                currentRound = 2,
                maxRounds = 2,
                participants = emptyList(),
                messages = emptyList(),
                summary = RoundSummary(
                    id = "s1",
                    version = 2,
                    degraded = false,
                    consensus = listOf(SummaryItem("先做实验", listOf("m1"))),
                ),
                lastSequence = 7,
                savedAt = 1L,
            )
        }
        val transport = SummaryTransport(SUMMARY_RESPONSE)
        val api = ApiClient("http://backend.test", transport)
        val controller = RoomController({ _, _, _ -> socket }, cache = cache)
        val viewModel = RoomViewModel(
            roundtableId = "room",
            controller = controller,
            api = api,
            cache = cache,
            sessionProvider = { "session" },
            summaryGenerator = RoundSummaryGenerator(
                api,
                ProviderChatClient(StreamSource { error("重启恢复不应调用模型") }),
                retryDelayMs = 0,
            ),
        )
        advanceUntilIdle()

        assertEquals(2, viewModel.view.value.summary?.version)
        assertEquals("completed", viewModel.view.value.status)
        assertTrue(transport.requests.none { it.url.endsWith("/summary") })

        controller.disconnect()
    }

    private companion object {
        const val SUMMARY_RESPONSE = """
            {"roundtable":{"id":"room","status":"completed","current_round":2,"last_sequence":6},
             "summary":{"id":"s1","version":1,"degraded":true,
               "consensus":[{"text":"先做实验","reference_message_ids":["m1"]}],
               "dissent":[],"recommendations":[],"unresolved":[],
               "created_at":"2026-10-26T01:05:03.456Z","updated_at":"2026-10-26T01:05:03.456Z"},
             "events":[]}
        """
    }
}
