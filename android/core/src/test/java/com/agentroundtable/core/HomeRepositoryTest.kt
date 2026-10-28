package com.agentroundtable.core

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.FakeTransport
import com.agentroundtable.core.model.RoundtableStatus
import com.agentroundtable.core.session.GuestSessionStore
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class InMemoryGuestSessionStore(private var sessionId: String? = null) : GuestSessionStore {
    var writes = 0
        private set

    override suspend fun read(): String? = sessionId

    override suspend fun write(sessionId: String) {
        this.sessionId = sessionId
        writes++
    }
}

class HomeRepositoryTest {
    private val transport = FakeTransport()
    private val api = ApiClient("http://backend.test", transport)

    @Test
    fun `first launch creates a guest session and stores its id`() = runTest {
        val store = InMemoryGuestSessionStore()
        transport.enqueue(201, """{"id":"8a1f","created_at":"2026-10-26T01:02:03.456Z"}""")
        transport.enqueue(200, "[]")

        val state = HomeRepository(api, store).load()

        assertEquals(HomeState.Empty, state)
        assertEquals(1, store.writes)
        assertEquals(listOf("/api/v1/guest-sessions", "/api/v1/roundtables"), transport.requests.map { it.url.substringAfter("test") })
    }

    @Test
    fun `existing guest session is reused and not recreated`() = runTest {
        val store = InMemoryGuestSessionStore("existing")
        transport.enqueue(200, "[]")

        HomeRepository(api, store).load()

        assertEquals(0, store.writes)
        assertEquals("existing", transport.requests.single().headers["X-Guest-Session"])
    }

    @Test
    fun `roundtables become cards with mapped status`() = runTest {
        val store = InMemoryGuestSessionStore("s")
        transport.enqueue(200, """
            [{"id":"r1","topic":"议题一","status":"running"},
             {"id":"r2","topic":"议题二","status":"completed"},
             {"id":"r3","topic":"议题三","status":"something-new"}]
        """.trimIndent())

        val state = HomeRepository(api, store).load()

        state as HomeState.Rooms
        assertEquals(3, state.items.size)
        assertEquals(RoundtableStatus.Running, state.items[0].status)
        assertEquals(RoundtableStatus.Completed, state.items[1].status)
        assertEquals(RoundtableStatus.Unknown, state.items[2].status)
        assertEquals("议题一", state.items[0].topic)
    }

    @Test
    fun `limit error surfaces the server message instead of an empty list`() = runTest {
        val store = InMemoryGuestSessionStore("s")
        transport.enqueue(429, """{"error":{"code":"active_roundtable_limit","message":"已有 3 个进行中的圆桌。"}}""")

        val state = HomeRepository(api, store).load()

        state as HomeState.Failed
        assertEquals("已有 3 个进行中的圆桌。", state.message)
    }

    @Test
    fun `session creation failure does not attempt to list roundtables`() = runTest {
        val store = InMemoryGuestSessionStore()
        transport.enqueue(500, """{"error":{"code":"unknown","message":"服务器错误。"}}""")

        val state = HomeRepository(api, store).load()

        assertTrue(state is HomeState.Failed)
        assertEquals(1, transport.requests.size)
        assertEquals(0, store.writes)
    }
}
