package com.agentroundtable.app.ui.create

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.api.HttpResponse
import com.agentroundtable.core.api.HttpTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

private class StubTransport(private val handler: (HttpRequest) -> HttpResponse) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()

    override suspend fun execute(request: HttpRequest): HttpResponse {
        requests += request
        return handler(request)
    }
}

class CreateViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `creating with a blank topic does not call the backend`() = runTest(dispatcher) {
        val transport = StubTransport { HttpResponse(200, PROFILES_JSON) }
        val viewModel = CreateViewModel(ApiClient("http://backend.test", transport)) { "session" }
        advanceUntilIdle()
        transport.requests.clear()

        viewModel.updateTopic("   ")
        viewModel.submit()
        advanceUntilIdle()

        assertEquals(0, transport.requests.size)
        assertNotNull(viewModel.state.value.message)
    }

    @Test
    fun `creating without three agents does not call the backend`() = runTest(dispatcher) {
        val transport = StubTransport { HttpResponse(200, PROFILES_JSON) }
        val viewModel = CreateViewModel(ApiClient("http://backend.test", transport)) { "session" }
        advanceUntilIdle()
        transport.requests.clear()

        viewModel.updateTopic("议题")
        viewModel.toggleProfile("a")
        viewModel.submit()
        advanceUntilIdle()

        assertEquals(0, transport.requests.size)
        assertNotNull(viewModel.state.value.message)
    }

    @Test
    fun `successful creation exposes the new roundtable id`() = runTest(dispatcher) {
        val transport = StubTransport { request ->
            if (request.method == "GET") {
                HttpResponse(200, PROFILES_JSON)
            } else {
                HttpResponse(201, ROUNDTABLE_JSON)
            }
        }
        val viewModel = CreateViewModel(ApiClient("http://backend.test", transport)) { "session" }
        advanceUntilIdle()

        viewModel.updateTopic("该不该把验证周期压缩到两周？")
        listOf("a", "b", "c").forEach(viewModel::toggleProfile)
        viewModel.submit()
        advanceUntilIdle()

        assertEquals("c0de", viewModel.state.value.createdRoundtableId)
        assertNull(viewModel.state.value.message)
        val post = transport.requests.last()
        assertEquals("POST", post.method)
        assertEquals("session", post.headers["X-Guest-Session"])
    }

    @Test
    fun `server limit error is surfaced instead of navigating away`() = runTest(dispatcher) {
        val transport = StubTransport { request ->
            if (request.method == "GET") {
                HttpResponse(200, PROFILES_JSON)
            } else {
                HttpResponse(429, """{"error":{"code":"active_roundtable_limit","message":"已有 3 个进行中的圆桌。"}}""")
            }
        }
        val viewModel = CreateViewModel(ApiClient("http://backend.test", transport)) { "session" }
        advanceUntilIdle()

        viewModel.updateTopic("议题")
        listOf("a", "b", "c").forEach(viewModel::toggleProfile)
        viewModel.submit()
        advanceUntilIdle()

        assertNull(viewModel.state.value.createdRoundtableId)
        assertEquals("已有 3 个进行中的圆桌。", viewModel.state.value.message)
    }

    private companion object {
        const val PROFILES_JSON = """
            [{"id":"a","key":"advocate","name":"方案派","tagline":"先给方案","expertise":"拆解",
              "goal":"推进","default_stance":"推进","style":"直接","banned_behaviors":[],"max_reply_chars":180},
             {"id":"b","key":"skeptic","name":"质疑派","tagline":"先找漏洞","expertise":"风险",
              "goal":"质疑","default_stance":"谨慎","style":"尖锐","banned_behaviors":[],"max_reply_chars":180},
             {"id":"c","key":"experience","name":"体验派","tagline":"从用户出发","expertise":"体验",
              "goal":"共情","default_stance":"中立","style":"温和","banned_behaviors":[],"max_reply_chars":180}]
        """

        const val ROUNDTABLE_JSON = """
            {"id":"c0de","topic":"该不该把验证周期压缩到两周？","status":"ready","mode":"decision",
             "max_rounds":2,"current_round":0,"last_sequence":0,"pause_pending":false,
             "active_turn":null,"provider":null,"parent_roundtable_id":null,
             "source_summary_id":null,"follow_up_context":null,
             "budget":{"max_rounds":2},"created_at":"2026-10-26T01:02:03.456Z",
             "updated_at":"2026-10-26T01:02:03.456Z","participants":[]}
        """
    }
}
