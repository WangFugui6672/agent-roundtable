package com.agentroundtable.core.turn

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.FakeTransport
import com.agentroundtable.core.knowledge.FakeEmbeddingBackend
import com.agentroundtable.core.knowledge.InMemoryRetrievalStore
import com.agentroundtable.core.knowledge.KnowledgeSearch
import com.agentroundtable.core.knowledge.RetrievalHit
import com.agentroundtable.core.provider.ProviderConfiguration
import com.agentroundtable.core.provider.ProviderKind
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnRunnerRetrievalTest {
    private val configuration =
        ProviderConfiguration(ProviderKind.DeepSeek, "https://api.deepseek.com/v1", "deepseek-chat")

    private val context = PromptContext(
        topic = "是否把验证周期压缩到两周？",
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

    private val transcript = listOf(
        TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1"),
        TranscriptLine("我", "预算只有两周", messageId = "m2", authorAgentId = null),
    )

    @Test
    fun `empty retrieval sends a request body byte-identical to no retrieval`() = runTest {
        val (legacyResult, legacyBody) = run(FakeTransport(), retrieval = null)
        val (withRetrievalResult, withRetrievalBody) =
            run(FakeTransport(), Retrieval { emptyList() })

        assertTrue(legacyResult is TurnRunResult.Spoke)
        assertTrue(withRetrievalResult is TurnRunResult.Spoke)
        assertArrayEquals(legacyBody.encodeToByteArray(), withRetrievalBody.encodeToByteArray())
        assertFalse(withRetrievalBody.contains("参考资料"))
    }

    @Test
    fun `an empty knowledge base behaves exactly like no retrieval`() = runTest {
        val store = InMemoryRetrievalStore()
        val backend = FakeEmbeddingBackend()
        val search = KnowledgeSearch(store = store, vectorStore = store, backend = backend)

        val (_, legacyBody) = run(FakeTransport(), retrieval = null)
        val (result, emptyLibraryBody) = run(FakeTransport(), Retrieval { search.search(it) })

        assertTrue(result is TurnRunResult.Spoke)
        assertArrayEquals(legacyBody.encodeToByteArray(), emptyLibraryBody.encodeToByteArray())
        // 空资料库不应触发嵌入后端，讨论行为与未接入资料库一致。
        assertTrue(backend.calls.isEmpty())
    }

    @Test
    fun `retrieved chunks are injected sorted capped and reported on the result`() = runTest {
        val hits = listOf(
            hit("低分文档块", similarity = 0.46f, documentId = "doc-low"),
            hit("最高分文档块", similarity = 0.9f, documentId = "doc-high", chunkIndex = 1),
            hit("中间分文档块", similarity = 0.7f, documentId = "doc-middle"),
            hit("次高分文档块", similarity = 0.8f, documentId = "doc-second"),
        )

        val (result, body) = run(FakeTransport(), Retrieval { hits })

        result as TurnRunResult.Spoke
        assertEquals("turn-1", result.turnId)
        assertEquals(
            listOf("最高分文档块", "次高分文档块", "中间分文档块"),
            result.references.map { it.text },
        )
        assertTrue(body.contains("参考资料"))
        assertTrue(body.contains("来源：最高分文档块（第 2 块）"))
        assertTrue(body.indexOf("最高分文档块") < body.indexOf("次高分文档块"))
        assertTrue(body.indexOf("次高分文档块") < body.indexOf("中间分文档块"))
        assertFalse(body.contains("低分文档块"))
    }

    @Test
    fun `retrieval uses the latest user message as the query`() = runTest {
        var query: String? = null
        run(FakeTransport(), Retrieval { received ->
            query = received
            emptyList()
        })

        assertEquals("预算只有两周", query)
    }

    @Test
    fun `retrieval falls back to the topic when there is no user message`() = runTest {
        var query: String? = null
        val agentOnly = listOf(
            TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1"),
        )
        run(
            FakeTransport(),
            Retrieval { received ->
                query = received
                emptyList()
            },
            turnTranscript = agentOnly,
        )

        assertEquals(context.topic, query)
    }

    @Test
    fun `an unavailable retrieval backend does not block the turn`() = runTest {
        val (_, legacyBody) = run(FakeTransport(), retrieval = null)
        val (result, body) = run(
            FakeTransport(),
            Retrieval { throw IllegalStateException("embedding model unavailable") },
        )

        assertTrue(result is TurnRunResult.Spoke)
        assertArrayEquals(legacyBody.encodeToByteArray(), body.encodeToByteArray())
        assertFalse(body.contains("参考资料"))
    }

    @Test
    fun `a timed out retrieval degrades to no retrieval without blocking the turn`() = runTest {
        val (_, legacyBody) = run(FakeTransport(), retrieval = null)
        val (result, body) = run(
            FakeTransport(),
            Retrieval {
                delay(10_000)
                listOf(hit("迟到的文档块", similarity = 0.9f))
            },
        )

        assertTrue(result is TurnRunResult.Spoke)
        assertArrayEquals(legacyBody.encodeToByteArray(), body.encodeToByteArray())
        assertFalse(body.contains("参考资料"))
    }

    private suspend fun run(
        transport: FakeTransport,
        retrieval: Retrieval?,
        turnTranscript: List<TranscriptLine> = transcript,
    ): Pair<TurnRunResult, String> {
        transport.enqueue(200, NEXT_TURN_JSON)
        transport.enqueue(201, "{}")

        var body = ""
        val chat = ProviderChatClient(
            StreamSource { request ->
                body = request.body.orEmpty()
                flowOf(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}",
                    "data: [DONE]",
                )
            },
        )
        val runner = TurnRunner(ApiClient("http://backend.test", transport), chat, retrieval)
        val result = runner.runOnce(
            sessionId = "s",
            roundtableId = "r",
            configuration = configuration,
            apiKey = "sk-test",
            transcript = turnTranscript,
            contextFor = { context },
            onDelta = {},
        )
        return result to body
    }

    private fun hit(
        text: String,
        similarity: Float,
        documentId: String = "doc",
        documentName: String = text,
        chunkIndex: Int = 0,
    ) = RetrievalHit(
        documentId = documentId,
        documentName = documentName,
        chunkIndex = chunkIndex,
        text = text,
        similarity = similarity,
    )

    private companion object {
        const val NEXT_TURN_JSON = """
            {"round":1,"turn":{"turn_id":"turn-1","round":1,"roundtable_agent_id":"p1",
             "position":0,"agent_key":"advocate","agent_name":"方案派"}}
        """
    }
}
