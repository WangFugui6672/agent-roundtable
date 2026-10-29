package com.agentroundtable.core.turn

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.FakeTransport
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderKind
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnRunnerTest {
    private val transport = FakeTransport()
    private val api = ApiClient("http://backend.test", transport)
    private val configuration = ProviderConfiguration(ProviderKind.DeepSeek, "https://api.deepseek.com/v1", "deepseek-chat")

    private val context = PromptContext(
        topic = "议题",
        agentName = "方案派",
        tagline = "先给方案",
        expertise = "拆解",
        goal = "推进",
        defaultStance = "倾向推进",
        style = "直接",
        bannedBehaviors = emptyList(),
        maxReplyChars = 180,
        roundNumber = 1,
    )

    @Test
    fun `a successful turn submits the composed message with the same turn id`() = runTest {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")
        val runner = TurnRunner(api, chatWith(listOf("先给出一个可执行的方案。", "然后再谈权衡。")))

        val result = runner.runOnce(
            sessionId = "s",
            roundtableId = "r",
            configuration = configuration,
            apiKey = "sk-test",
            transcript = emptyList(),
            contextFor = { context },
            onDelta = {},
        )

        assertTrue(result is TurnRunResult.Spoke)
        val submit = transport.requests.last()
        assertEquals("POST", submit.method)
        assertTrue(submit.url.endsWith("/messages"))
        assertTrue(submit.body.orEmpty().contains("\"turn_id\":\"turn-1\""))
        assertTrue(submit.body.orEmpty().contains("\"claim\":\"先给出一个可执行的方案\""))
        assertTrue(submit.body.orEmpty().contains("\"message_type\":\"proposal\""))
        assertTrue(!submit.body.orEmpty().contains("sk-test"))
    }

    @Test
    fun `PASS closes the turn without creating a message`() = runTest {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")
        val runner = TurnRunner(api, chatWith(listOf("PASS")))

        val result = runner.runOnce("s", "r", configuration, "sk-test", emptyList(), { context }, {})

        assertEquals(TurnRunResult.Passed, result)
        assertTrue(transport.requests.last().url.endsWith("/turns/pass"))
    }

    @Test
    fun `an empty reply fails the turn as retryable`() = runTest {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")
        val runner = TurnRunner(api, chatWith(emptyList()))

        val result = runner.runOnce("s", "r", configuration, "sk-test", emptyList(), { context }, {})

        result as TurnRunResult.Failed
        assertTrue(result.retryable)
        val fail = transport.requests.last()
        assertTrue(fail.url.endsWith("/turns/fail"))
        assertTrue(fail.body.orEmpty().contains("provider_empty_reply"))
    }

    @Test
    fun `no available turn is not an error`() = runTest {
        transport.enqueue(200, """{"round":1,"turn":null}""")
        val runner = TurnRunner(api, chatWith(listOf("x")))

        val result = runner.runOnce("s", "r", configuration, "sk-test", emptyList(), { context }, {})

        assertEquals(TurnRunResult.NoTurn, result)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `deltas are streamed to the caller before the turn is submitted`() = runTest {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")
        val deltas = mutableListOf<String>()
        val runner = TurnRunner(api, chatWith(listOf("一", "二")))

        runner.runOnce("s", "r", configuration, "sk-test", emptyList(), { context }, { deltas += it })

        assertEquals(listOf("一", "二"), deltas)
    }

    @Test
    fun `the prompt includes the topic and the transcript`() = runTest {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")
        var captured: String? = null
        val source = StreamSource { request ->
            captured = request.body
            flowOf("data: [DONE]")
        }
        val runner = TurnRunner(api, ProviderChatClient(source))

        runner.runOnce(
            "s", "r", configuration, "sk-test",
            listOf(TranscriptLine("质疑派", "我不同意")),
            { context },
            {},
        )

        assertTrue(captured.orEmpty().contains("议题"))
        assertTrue(captured.orEmpty().contains("质疑派：我不同意"))
    }

    private fun chatWith(chunks: List<String>) = ProviderChatClient(
        StreamSource { _ ->
            flowOf(
                *chunks.map { chunk ->
                    "data: {\"choices\":[{\"delta\":{\"content\":${quote(chunk)}}}]}"
                }.toTypedArray(),
                "data: [DONE]",
            )
        },
    )

    private fun quote(text: String) = "\"" + text + "\""

    private companion object {
        const val NEXT_TURN_JSON = """
            {"round":1,"turn":{"turn_id":"turn-1","round":1,"roundtable_agent_id":"p1",
             "position":0,"agent_key":"advocate","agent_name":"方案派"}}
        """
    }
}
