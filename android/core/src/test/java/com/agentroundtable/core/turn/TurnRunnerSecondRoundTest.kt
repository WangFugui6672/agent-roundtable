package com.agentroundtable.core.turn

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.FakeTransport
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderKind
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnRunnerSecondRoundTest {
    private val transport = FakeTransport()
    private val api = ApiClient("http://backend.test", transport)
    private val configuration =
        ProviderConfiguration(ProviderKind.DeepSeek, "https://api.deepseek.com/v1", "deepseek-chat")

    private val context = PromptContext(
        topic = "议题",
        agentName = "质疑派",
        tagline = "先找漏洞",
        expertise = "风险",
        goal = "质疑",
        defaultStance = "谨慎",
        style = "尖锐",
        bannedBehaviors = emptyList(),
        maxReplyChars = 180,
        roundNumber = 2,
    )

    private fun quote(text: String) = "\"" + text.replace("\"", "\\\"") + "\""

    @Test
    fun `second round submits a structured reply with its reference`() = runTest {
        transport.enqueue(
            200,
            """{"round":2,"turn":{"turn_id":"t2","round":2,"roundtable_agent_id":"p2","position":1,"agent_key":"skeptic","agent_name":"质疑派"}}""",
        )
        transport.enqueue(201, "{}")

        val json = """{"message_type":"challenge","claim":"成本被低估","body":"我质疑这个判断。","stance":"challenge","reference_message_id":"m1","challenge_target_agent_id":"p1"}"""
        val runner = TurnRunner(api, ProviderChatClient(StreamSource { _ ->
            flowOf("data: {\"choices\":[{\"delta\":{\"content\":${quote(json)}}}]}", "data: [DONE]")
        }))

        val result = runner.runOnce(
            sessionId = "s",
            roundtableId = "r",
            configuration = configuration,
            apiKey = "sk-test",
            transcript = listOf(
                TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1"),
            ),
            contextFor = { context },
            onDelta = {},
        )

        assertTrue(result is TurnRunResult.Spoke)
        val body = transport.requests.last().body.orEmpty()
        assertTrue(body.contains("\"message_type\":\"challenge\""))
        assertTrue(body.contains("\"references\":[\"m1\"]"))
        assertTrue(body.contains("\"challenge_target_agent_id\":\"p1\""))
    }

    @Test
    fun `an invalid structured reply fails the turn as retryable`() = runTest {
        transport.enqueue(
            200,
            """{"round":2,"turn":{"turn_id":"t2","round":2,"roundtable_agent_id":"p2","position":1,"agent_key":"skeptic","agent_name":"质疑派"}}""",
        )
        transport.enqueue(201, "{}")

        val json = """{"message_type":"supplement","claim":"补充","body":"正文","stance":"supplement"}"""
        val runner = TurnRunner(api, ProviderChatClient(StreamSource { _ ->
            flowOf("data: {\"choices\":[{\"delta\":{\"content\":${quote(json)}}}]}", "data: [DONE]")
        }))

        val result = runner.runOnce(
            "s", "r", configuration, "sk-test",
            listOf(TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1")),
            { context }, {},
        )

        result as TurnRunResult.Failed
        assertTrue(result.retryable)
        assertTrue(transport.requests.last().url.endsWith("/turns/fail"))
    }
}
