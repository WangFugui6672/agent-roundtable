package com.agentroundtable.core.turn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StructuredReplyTest {
    private val candidates = listOf(
        TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "agent-a"),
        TranscriptLine("体验派", "用户等不了", messageId = "m2", authorAgentId = "agent-c"),
    )

    @Test
    fun `a valid challenge against the referenced author is accepted`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"challenge","claim":"成本被低估","body":"我质疑这个判断。",
                "stance":"challenge","reference_message_id":"m1","challenge_target_agent_id":"agent-a"}""",
            candidates,
            currentAgentId = "agent-b",
        )

        result as ReplyParseResult.Valid
        assertEquals("m1", result.reply.referenceMessageId)
    }

    @Test
    fun `PASS is reported separately from invalid replies`() {
        assertEquals(
            ReplyParseResult.Pass,
            StructuredReplyParser.parse("PASS", candidates, "agent-b"),
        )
    }

    @Test
    fun `a reply without a reference is rejected`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"supplement","claim":"补充","body":"正文","stance":"supplement"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `referencing a non-existent message is rejected`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"support","claim":"同意","body":"正文","stance":"support",
                "reference_message_id":"missing"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `referencing your own message is rejected`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"support","claim":"同意","body":"正文","stance":"support",
                "reference_message_id":"m1"}""",
            candidates,
            currentAgentId = "agent-a",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `challenge must target the author of the referenced message`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"challenge","claim":"质疑","body":"正文","stance":"challenge",
                "reference_message_id":"m1","challenge_target_agent_id":"agent-c"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `challenge without a target is rejected`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"challenge","claim":"质疑","body":"正文","stance":"challenge",
                "reference_message_id":"m1"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `stance must match message type`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"support","claim":"同意","body":"正文","stance":"challenge",
                "reference_message_id":"m1"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `an unknown message type is rejected`() {
        val result = StructuredReplyParser.parse(
            """{"message_type":"proposal","claim":"提案","body":"正文","stance":"proposal",
                "reference_message_id":"m1"}""",
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }

    @Test
    fun `json wrapped in a code fence is still parsed`() {
        val result = StructuredReplyParser.parse(
            """
            ```json
            {"message_type":"supplement","claim":"补充","body":"正文","stance":"supplement",
             "reference_message_id":"m2"}
            ```
            """.trimIndent(),
            candidates,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Valid)
    }

    @Test
    fun `a user message is not a valid reference target`() {
        val withUser = candidates + TranscriptLine("用户", "我说一句", messageId = "m3", authorAgentId = null)

        val result = StructuredReplyParser.parse(
            """{"message_type":"support","claim":"同意","body":"正文","stance":"support",
                "reference_message_id":"m3"}""",
            withUser,
            "agent-b",
        )

        assertTrue(result is ReplyParseResult.Invalid)
    }
}

class ChatStreamFailureTest {
    @Test
    fun `a transport exception becomes a failed stream event instead of throwing`() = kotlinx.coroutines.test.runTest {
        val client = com.agentroundtable.core.turn.ProviderChatClient(
            com.agentroundtable.core.turn.StreamSource {
                throw java.net.UnknownHostException("Unable to resolve host")
            },
        )

        val events = mutableListOf<com.agentroundtable.core.turn.ChatStreamEvent>()
        client.stream(
            com.agentroundtable.core.provider.ProviderConfiguration(
                com.agentroundtable.core.provider.ProviderKind.Custom,
                "http://127.0.0.1:18080/v1",
                "fake-model",
            ),
            "test-key",
            listOf(com.agentroundtable.core.turn.ChatMessage.user("hi")),
        ).collect { events += it }

        org.junit.Assert.assertTrue(events.single() is com.agentroundtable.core.turn.ChatStreamEvent.Failed)
    }
}
