package com.agentroundtable.core.api

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ApiClientTest {
    private val transport = FakeTransport()
    private val api = ApiClient(baseUrl = "http://backend.test", transport = transport)

    @Test
    fun `creating a guest session decodes id and timestamp`() = runTest {
        transport.enqueue(201, """{"id":"8a1f","created_at":"2026-10-26T01:02:03.456Z"}""")

        val result = api.createGuestSession()

        assertTrue(result is ApiResult.Success)
        val session = (result as ApiResult.Success).value
        assertEquals("8a1f", session.id)
        assertEquals("2026-10-26T01:02:03.456Z", session.createdAt)
    }

    @Test
    fun `listing roundtables sends the guest session header`() = runTest {
        transport.enqueue(200, "[]")

        api.listRoundtables(sessionId = "8a1f")

        assertEquals("http://backend.test/api/v1/roundtables", transport.requests.single().url)
        assertEquals("8a1f", transport.requests.single().headers["X-Guest-Session"])
    }

    @Test
    fun `creating a roundtable posts the topic and agent ids`() = runTest {
        transport.enqueue(201, ROUNDTABLE_JSON)

        val result = api.createRoundtable(
            sessionId = "8a1f",
            topic = "该不该把验证周期压缩到两周？",
            agentProfileIds = listOf("a", "b", "c"),
        )

        val body = transport.requests.single().body.orEmpty()
        assertTrue(body.contains("\"topic\""))
        assertTrue(body.contains("\"agent_profile_ids\":[\"a\",\"b\",\"c\"]"))
        assertTrue(result is ApiResult.Success)
    }

    @Test
    fun `error envelope maps to a stable code`() = runTest {
        transport.enqueue(
            429,
            """{"error":{"code":"active_roundtable_limit","message":"已有 3 个进行中的圆桌。"}}""",
        )

        val result = api.createRoundtable("8a1f", "议题", listOf("a", "b", "c"))

        result as ApiResult.Failure
        assertEquals(ApiErrorCode.ActiveRoundtableLimit, result.code)
        assertEquals("已有 3 个进行中的圆桌。", result.message)
        assertEquals(429, result.httpStatus)
    }

    @Test
    fun `unknown error code degrades to Unknown without losing the message`() = runTest {
        transport.enqueue(418, """{"error":{"code":"teapot","message":"服务端异常。"}}""")

        val result = api.listAgentProfiles()

        result as ApiResult.Failure
        assertEquals(ApiErrorCode.Unknown, result.code)
        assertEquals("服务端异常。", result.message)
    }

    @Test
    fun `network failure becomes a readable failure instead of an exception`() = runTest {
        transport.throwOnNext = java.io.IOException("connection reset")

        val result = api.listAgentProfiles()

        result as ApiResult.Failure
        assertEquals(ApiErrorCode.Unknown, result.code)
        assertEquals(0, result.httpStatus)
        assertTrue(result.message.isNotBlank())
    }

    @Test
    fun `malformed body becomes a readable failure instead of a crash`() = runTest {
        transport.enqueue(200, "<html>gateway</html>")

        val result = api.listAgentProfiles()

        assertTrue(result is ApiResult.Failure)
    }

    @Test
    fun `error response without an envelope still reports the http status`() = runTest {
        transport.enqueue(502, "bad gateway")

        val result = api.listAgentProfiles()

        result as ApiResult.Failure
        assertEquals(502, result.httpStatus)
        assertEquals(ApiErrorCode.Unknown, result.code)
    }

    @Test
    fun `reading a missing summary returns null`() = runTest {
        transport.enqueue(200, """{"summary":null}""")

        val result = api.getSummary(sessionId = "8a1f", roundtableId = "c0de")

        result as ApiResult.Success
        org.junit.Assert.assertNull(result.value.summary)
        assertEquals("http://backend.test/api/v1/roundtables/c0de/summary", transport.requests.single().url)
        assertEquals("8a1f", transport.requests.single().headers["X-Guest-Session"])
    }

    @Test
    fun `submitting a summary sends the expected version and reference ids`() = runTest {
        transport.enqueue(201, SUMMARY_RESPONSE_JSON)

        val result = api.submitSummary(
            sessionId = "8a1f",
            roundtableId = "c0de",
            submission = com.agentroundtable.core.model.RoundSummarySubmission(
                expectedVersion = 2,
                degraded = true,
                consensus = listOf(
                    com.agentroundtable.core.model.SummaryItem("先做实验", listOf("m1")),
                ),
                dissent = emptyList(),
                recommendations = emptyList(),
                unresolved = emptyList(),
            ),
        )

        result as ApiResult.Success
        assertEquals(3, result.value.summary.version)
        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertTrue(request.body.orEmpty().contains("\"expected_version\":2"))
        assertTrue(request.body.orEmpty().contains("\"reference_message_ids\":[\"m1\"]"))
        assertTrue(request.body.orEmpty().contains("\"degraded\":true"))
    }

    private companion object {
        const val SUMMARY_RESPONSE_JSON = """
            {"roundtable":{"id":"c0de","status":"completed","current_round":2,"last_sequence":9},
             "summary":{"id":"s1","version":3,"degraded":true,
               "consensus":[{"text":"先做实验","reference_message_ids":["m1"]}],
               "dissent":[],"recommendations":[],"unresolved":[],
               "created_at":"2026-10-26T01:05:03.456Z","updated_at":"2026-10-26T01:05:03.456Z"},
             "events":[]}
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
