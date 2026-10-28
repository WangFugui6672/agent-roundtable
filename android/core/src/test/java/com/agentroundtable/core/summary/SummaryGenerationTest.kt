package com.agentroundtable.core.summary

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.FakeTransport
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderKind
import com.agentroundtable.core.room.Message
import com.agentroundtable.core.room.MessageAuthor
import com.agentroundtable.core.turn.ProviderChatClient
import com.agentroundtable.core.turn.StreamSource
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StructuredSummaryTest {
    private val transcript = listOf(
        message("m1", type = "proposal", body = "先做两周验证", claim = "先做实验"),
        message("m2", type = "support", body = "同意先做实验", claim = "支持小实验"),
        message("m3", type = "challenge", body = "成本被低估", claim = "成本风险"),
        message("m4", type = "question", body = "谁负责？", claim = "负责人未定"),
        message("m5", type = "supplement", body = "补充一个指标", claim = "补充指标"),
    )

    @Test
    fun `valid model output maps reference indexes to real message ids`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"先做实验","reference_indexes":[0]}],
                "dissent":[{"text":"成本风险","reference_indexes":[2,3]}],
                "recommendations":[],"unresolved":[]}""",
            transcript,
        )

        result as SummaryParseResult.Valid
        assertFalse(result.draft.degraded)
        assertEquals(listOf("m1"), result.draft.consensus.single().referenceMessageIds)
        assertEquals(listOf("m3", "m4"), result.draft.dissent.single().referenceMessageIds)
    }

    @Test
    fun `key points are offered before ordinary messages`() {
        val marked = transcript.map { if (it.id == "m3") it.copy(isKeyPoint = true) else it }

        val eligible = StructuredSummaryParser.eligibleMessages(marked)

        assertEquals("m3", eligible.first().id)
    }

    @Test
    fun `user messages and superseded replies are not valid sources`() {
        val withUser = transcript + message(
            "user-1",
            type = "proposal",
            body = "用户观点",
            authorType = "user",
            agentId = null,
        )
        val withSuperseded = withUser + message(
            "old",
            type = "proposal",
            body = "旧回复",
            supersededBy = "m2",
        )

        val eligible = StructuredSummaryParser.eligibleMessages(withSuperseded)

        assertTrue(eligible.none { it.id == "user-1" })
        assertTrue(eligible.none { it.id == "old" })
    }

    @Test
    fun `an index outside the candidate list is rejected`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"越界","reference_indexes":[99]}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        result as SummaryParseResult.Invalid
        assertTrue(result.reason.contains("候选讨论之外"))
    }

    @Test
    fun `duplicate references are rejected`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"重复","reference_indexes":[0,0]}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        result as SummaryParseResult.Invalid
        assertTrue(result.reason.contains("重复引用"))
    }

    @Test
    fun `more than three references are rejected`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"太多引用","reference_indexes":[0,1,2,3]}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        result as SummaryParseResult.Invalid
        assertTrue(result.reason.contains("1 到 3"))
    }

    @Test
    fun `more than eight items in one section is rejected`() {
        val items = (0 until 9).joinToString(",") {
            """{"text":"第 $it 项","reference_indexes":[0]}"""
        }
        val result = StructuredSummaryParser.parse(
            """{"consensus":[$items],"dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        result as SummaryParseResult.Invalid
        assertTrue(result.reason.contains("最多 8 项"))
    }

    @Test
    fun `blank or overlong text is rejected`() {
        val blank = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"   ","reference_indexes":[0]}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )
        assertTrue(blank is SummaryParseResult.Invalid)

        val overlong = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"${"长".repeat(401)}","reference_indexes":[0]}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )
        overlong as SummaryParseResult.Invalid
        assertTrue(overlong.reason.contains("400"))
    }

    @Test
    fun `an all-empty summary is rejected`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[],"dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        assertTrue(result is SummaryParseResult.Invalid)
    }

    @Test
    fun `non-json output gives a readable reason`() {
        val result = StructuredSummaryParser.parse("这不是 JSON", transcript)

        result as SummaryParseResult.Invalid
        assertTrue(result.reason.contains("不是合法 JSON"))
    }

    @Test
    fun `json wrapped in a code fence is accepted`() {
        val result = StructuredSummaryParser.parse(
            """
            ```json
            {"consensus":[{"text":"先做实验","reference_indexes":[0]}],
             "dissent":[],"recommendations":[],"unresolved":[]}
            ```
            """.trimIndent(),
            transcript,
        )

        assertTrue(result is SummaryParseResult.Valid)
    }

    @Test
    fun `extra keys are rejected instead of silently ignored`() {
        val result = StructuredSummaryParser.parse(
            """{"consensus":[{"text":"先做实验","reference_indexes":[0],"invented":true}],
                "dissent":[],"recommendations":[],"unresolved":[]}""",
            transcript,
        )

        assertTrue(result is SummaryParseResult.Invalid)
    }

    private fun message(
        id: String,
        type: String,
        body: String,
        claim: String? = null,
        authorType: String = "agent",
        agentId: String? = "a1",
        supersededBy: String? = null,
    ) = Message(
        id = id,
        author = MessageAuthor(
            type = authorType,
            roundtableAgentId = agentId,
            agentKey = "advocate",
            name = if (authorType == "user") "用户" else "方案派",
        ),
        messageType = type,
        claim = claim,
        body = body,
        supersededByMessageId = supersededBy,
    )
}

class RuleBasedSummaryTest {
    @Test
    fun `every section comes from real agent messages and is marked degraded`() {
        val transcript = listOf(
            message("s1", "support", "支持先做实验"),
            message("c1", "challenge", "成本被低估"),
            message("p1", "proposal", "建议两周验证"),
            message("q1", "question", "谁负责？"),
            message("u1", "proposal", "用户自己的观点", authorType = "user"),
        )

        val draft = RuleBasedSummary.make(transcript)

        assertTrue(draft.degraded)
        assertEquals(listOf("s1"), draft.consensus.map { it.referenceMessageIds.single() })
        assertEquals(listOf("c1"), draft.dissent.map { it.referenceMessageIds.single() })
        assertEquals(listOf("p1"), draft.recommendations.map { it.referenceMessageIds.single() })
        assertEquals(listOf("q1"), draft.unresolved.map { it.referenceMessageIds.single() })
        val allIds = transcript.map { it.id }.toSet()
        assertTrue(
            listOf(draft.consensus, draft.dissent, draft.recommendations, draft.unresolved)
                .flatten()
                .flatMap { it.referenceMessageIds }
                .all { it in allIds },
        )
        assertTrue(draft.consensus.single().text.isNotBlank())
    }

    @Test
    fun `a blank claim falls back to the message body`() {
        val draft = RuleBasedSummary.make(
            listOf(message("m1", "support", "正文观点", claim = "")),
        )

        assertEquals("正文观点", draft.consensus.single().text)
    }

    @Test
    fun `messages without any usable text are skipped`() {
        val draft = RuleBasedSummary.make(
            listOf(message("blank", "support", "   ", claim = "")),
        )

        assertTrue(draft.consensus.isEmpty())
    }

    private fun message(
        id: String,
        type: String,
        body: String,
        claim: String? = null,
        authorType: String = "agent",
    ) = Message(
        id = id,
        author = MessageAuthor(
            type = authorType,
            roundtableAgentId = if (authorType == "agent") "a1" else null,
            agentKey = "advocate",
            name = if (authorType == "agent") "方案派" else "用户",
        ),
        messageType = type,
        claim = claim,
        body = body,
    )
}

class RoundSummaryGeneratorTest {
    private val transport = FakeTransport()
    private val api = ApiClient("http://backend.test", transport)
    private val configuration = ProviderConfiguration(
        ProviderKind.DeepSeek,
        "https://api.deepseek.com/v1",
        "deepseek-chat",
    )
    private val transcript = listOf(
        message("m1", "support", "支持先做实验", "先做实验"),
        message("m2", "challenge", "成本被低估", "成本风险"),
    )

    @Test
    fun `valid model output is submitted without a fallback flag`() = runTest {
        transport.enqueue(201, responseJson(degraded = false))
        val generator = RoundSummaryGenerator(
            api,
            chatWith(
                """{"consensus":[{"text":"先做实验","reference_indexes":[0]}],
                    "dissent":[{"text":"成本风险","reference_indexes":[1]}],
                    "recommendations":[],"unresolved":[]}""",
            ),
            retryDelayMs = 0,
        )

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = configuration, apiKey = "sk-test",
        )

        assertTrue(result is SummaryRunResult.Saved)
        val body = transport.requests.single().body.orEmpty()
        assertTrue(body.contains("\"expected_version\":0"))
        assertTrue(body.contains("\"degraded\":false"))
        assertTrue(body.contains("\"reference_message_ids\":[\"m1\"]"))
        assertFalse(body.contains("sk-test"))
    }

    @Test
    fun `invalid model output falls back to a degraded rule-based summary`() = runTest {
        transport.enqueue(201, responseJson(degraded = true))
        val generator = RoundSummaryGenerator(api, chatWith("不是 JSON"), retryDelayMs = 0)

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = configuration, apiKey = "sk-test",
        )

        assertTrue(result is SummaryRunResult.Saved)
        val saved = result as SummaryRunResult.Saved
        assertTrue(saved.draft.degraded)
        val body = transport.requests.single().body.orEmpty()
        assertTrue(body.contains("\"degraded\":true"))
        assertTrue(body.contains("\"reference_message_ids\":[\"m1\"]"))
    }

    @Test
    fun `an invalid first response is retried once and a valid retry is accepted`() = runTest {
        transport.enqueue(201, responseJson(degraded = false))
        var calls = 0
        val valid = """{"consensus":[{"text":"先做实验","reference_indexes":[0]}],
            "dissent":[],"recommendations":[],"unresolved":[]}"""
        val source = StreamSource { _ ->
            calls += 1
            val content = if (calls == 1) "不是 JSON" else valid
            flowOf(
                "data: {\"choices\":[{\"delta\":{\"content\":${JsonPrimitive(content)}}}]}",
                "data: [DONE]",
            )
        }
        val generator = RoundSummaryGenerator(api, ProviderChatClient(source), retryDelayMs = 0)

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = configuration, apiKey = "sk-test",
        )

        assertTrue(result is SummaryRunResult.Saved)
        assertFalse((result as SummaryRunResult.Saved).draft.degraded)
        assertEquals(2, calls)
    }

    @Test
    fun `missing provider uses the degraded path without calling the model`() = runTest {
        transport.enqueue(201, responseJson(degraded = true))
        val generator = RoundSummaryGenerator(
            api,
            ProviderChatClient(StreamSource { error("不应调用模型") }),
            retryDelayMs = 0,
        )

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = null, apiKey = null,
        )

        assertTrue(result is SummaryRunResult.Saved)
        assertTrue((result as SummaryRunResult.Saved).draft.degraded)
    }

    @Test
    fun `network retries submit the exact same body`() = runTest {
        transport.throwOnNext = java.io.IOException("connection reset")
        transport.enqueue(200, responseJson(degraded = true, version = 1))
        val generator = RoundSummaryGenerator(
            api,
            ProviderChatClient(StreamSource { error("不应调用模型") }),
            retryDelayMs = 0,
        )

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = null, apiKey = null,
        )

        assertTrue(result is SummaryRunResult.Saved)
        assertEquals(2, transport.requests.size)
        assertEquals(transport.requests[0].body, transport.requests[1].body)
        assertEquals(transport.requests[0].headers, transport.requests[1].headers)
    }

    @Test
    fun `regeneration sends the current version and conflicts are explicit`() = runTest {
        transport.enqueue(
            409,
            """{"error":{"code":"summary_version_conflict","message":"结论已被其他生成结果更新，请刷新后重试。"}}""",
        )
        val generator = RoundSummaryGenerator(
            api,
            ProviderChatClient(StreamSource { error("不应调用模型") }),
            retryDelayMs = 0,
        )

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 3,
            configuration = null, apiKey = null,
        )

        result as SummaryRunResult.Conflict
        assertTrue(result.message.contains("版本冲突"))
        assertEquals(1, transport.requests.size)
        assertTrue(transport.requests.single().body.orEmpty().contains("\"expected_version\":3"))
    }

    @Test
    fun `a non-retryable rejection is surfaced without duplicate attempts`() = runTest {
        transport.enqueue(
            400,
            """{"error":{"code":"validation_error","message":"结论引用必须指向当前圆桌中已经存在的有效 Agent 观点。"}}""",
        )
        val generator = RoundSummaryGenerator(
            api,
            ProviderChatClient(StreamSource { error("不应调用模型") }),
            retryDelayMs = 0,
        )

        val result = generator.generateAndSubmit(
            "session", "room", "议题", transcript, expectedVersion = 0,
            configuration = null, apiKey = null,
        )

        result as SummaryRunResult.Failed
        assertTrue(result.message.startsWith("结论保存失败"))
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `summary prompt lists candidates with stable indexes`() {
        val prompt = SummaryPrompt.messages("议题", transcript)

        val user = prompt.last().content
        assertTrue(user.contains("[0] 作者：方案派"))
        assertTrue(user.contains("[1] 作者：方案派"))
        assertTrue(prompt.first().content.contains("reference_indexes"))
    }

    private fun chatWith(content: String) = ProviderChatClient(
        StreamSource { _ ->
            flowOf(
                "data: {\"choices\":[{\"delta\":{\"content\":${JsonPrimitive(content)}}}]}",
                "data: [DONE]",
            )
        },
    )

    private fun message(id: String, type: String, body: String, claim: String) = Message(
        id = id,
        author = MessageAuthor(
            type = "agent",
            roundtableAgentId = "a1",
            agentKey = "advocate",
            name = "方案派",
        ),
        messageType = type,
        claim = claim,
        body = body,
    )

    private fun responseJson(degraded: Boolean, version: Int = 1) = """
        {"roundtable":{"id":"room","status":"completed","current_round":2,"last_sequence":12},
         "summary":{"id":"summary-1","version":$version,"degraded":$degraded,
           "consensus":[{"text":"先做实验","reference_message_ids":["m1"]}],
           "dissent":[],"recommendations":[],"unresolved":[],
           "created_at":"2026-10-26T01:05:03.456Z","updated_at":"2026-10-26T01:05:03.456Z"},
         "events":[]}
    """.trimIndent()
}
