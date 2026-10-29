package com.agentroundtable.core.turn

import com.agentroundtable.core.knowledge.RetrievalHit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentPromptTest {
    private val context = PromptContext(
        topic = "是否把验证周期压缩到两周？",
        agentId = "p1",
        agentName = "方案派",
        tagline = "先给方案",
        expertise = "拆解",
        goal = "推进",
        defaultStance = "倾向推进",
        style = "直接",
        bannedBehaviors = listOf("空话", "攻击个人"),
        maxReplyChars = 180,
        roundNumber = 1,
    )

    private val transcript = listOf(
        TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1"),
        TranscriptLine("我", "预算只有两周", messageId = "m2", authorAgentId = null),
    )

    @Test
    fun `without references the system prompt is byte-identical to the pre-RAG prompt`() {
        val expected = EXPECTED_ROUND_ONE_SYSTEM
        val actual = AgentPrompt.systemPrompt(context)

        assertArrayEquals(expected.encodeToByteArray(), actual.encodeToByteArray())
        assertArrayEquals(
            expected.encodeToByteArray(),
            AgentPrompt.systemPrompt(context, emptyList()).encodeToByteArray(),
        )
        assertFalse(actual.contains("参考资料"))
    }

    @Test
    fun `without references both messages are byte-identical to the pre-RAG prompt`() {
        val messages = AgentPrompt.messages(context, transcript)

        assertEquals(listOf("system", "user"), messages.map { it.role })
        assertArrayEquals(
            EXPECTED_ROUND_ONE_SYSTEM.encodeToByteArray(),
            messages[0].content.encodeToByteArray(),
        )
        assertArrayEquals(
            EXPECTED_ROUND_ONE_USER.encodeToByteArray(),
            messages[1].content.encodeToByteArray(),
        )
    }

    @Test
    fun `second round prompts are byte-identical to the pre-RAG prompt`() {
        val secondRound = context.copy(
            agentId = "p2",
            agentName = "质疑派",
            tagline = "先找漏洞",
            expertise = "风险",
            goal = "质疑",
            defaultStance = "谨慎",
            style = "尖锐",
            bannedBehaviors = emptyList(),
            roundNumber = 2,
        )
        val secondRoundTranscript = listOf(
            TranscriptLine("方案派", "先做两周验证", messageId = "m1", authorAgentId = "p1"),
            TranscriptLine("质疑派", "我不同意", messageId = "m2", authorAgentId = "p2"),
        )

        val messages = AgentPrompt.messages(secondRound, secondRoundTranscript)

        assertArrayEquals(
            EXPECTED_ROUND_TWO_SYSTEM.encodeToByteArray(),
            messages[0].content.encodeToByteArray(),
        )
        assertArrayEquals(
            EXPECTED_ROUND_TWO_USER.encodeToByteArray(),
            messages[1].content.encodeToByteArray(),
        )
        assertFalse(messages[0].content.contains("参考资料"))
    }

    @Test
    fun `references are sorted by similarity and capped at three`() {
        val hits = listOf(
            hit("低分文档块", 0.46f, documentId = "doc-low"),
            hit("最高分文档块", 0.9f, documentId = "doc-high", chunkIndex = 1),
            hit("中间分文档块", 0.7f, documentId = "doc-middle"),
            hit("次高分文档块", 0.8f, documentId = "doc-second"),
        )

        val selected = AgentPrompt.selectReferences(hits)

        assertEquals(
            listOf("最高分文档块", "次高分文档块", "中间分文档块"),
            selected.map { it.text },
        )
    }

    @Test
    fun `references form a separate section at the end of the system prompt`() {
        val hits = listOf(
            hit("低分文档块", 0.46f, documentId = "doc-low"),
            hit("最高分文档块", 0.9f, documentId = "doc-high", chunkIndex = 1),
            hit("中间分文档块", 0.7f, documentId = "doc-middle"),
            hit("次高分文档块", 0.8f, documentId = "doc-second"),
        )
        val base = AgentPrompt.systemPrompt(context)
        val system = AgentPrompt.systemPrompt(context, hits)

        assertTrue(system.startsWith(base))
        val section = system.removePrefix(base)
        assertTrue(section.startsWith("\n\n参考资料"))
        assertTrue(section.contains("来源：文档-doc-high（第 2 块）"))
        assertTrue(section.indexOf("最高分文档块") < section.indexOf("次高分文档块"))
        assertTrue(section.indexOf("次高分文档块") < section.indexOf("中间分文档块"))
        assertFalse(section.contains("低分文档块"))
        // 参考资料是 system prompt 的最后一段，后面不再追加任何指令。
        assertTrue(system.endsWith("中间分文档块"))
    }

    @Test
    fun `references do not change the user prompt`() {
        val hits = listOf(hit("相关文档块", 0.9f))

        val without = AgentPrompt.messages(context, transcript)
        val withReferences = AgentPrompt.messages(context, transcript, hits)

        assertEquals(without[1], withReferences[1])
        assertArrayEquals(
            without[1].content.encodeToByteArray(),
            withReferences[1].content.encodeToByteArray(),
        )
        assertTrue(withReferences[0].content.contains("参考资料"))
    }

    @Test
    fun `empty references produce no reference section`() {
        val base = AgentPrompt.systemPrompt(context)

        assertEquals(base, AgentPrompt.systemPrompt(context, emptyList()))
        assertTrue(AgentPrompt.selectReferences(emptyList()).isEmpty())
    }

    private fun hit(
        text: String,
        similarity: Float,
        documentId: String = "doc",
        documentName: String = "文档-$documentId",
        chunkIndex: Int = 0,
    ) = RetrievalHit(
        documentId = documentId,
        documentName = documentName,
        chunkIndex = chunkIndex,
        text = text,
        similarity = similarity,
    )

    private companion object {
        const val EXPECTED_ROUND_ONE_SYSTEM =
            "你是圆桌讨论中的「方案派」，先给方案。\n" +
                "你始终是 AI，不得声称自己是真人、公众人物，也不得冒充任何真实个人。\n" +
                "专长：拆解\n" +
                "当前目标：推进\n" +
                "默认立场：倾向推进\n" +
                "表达风格：直接\n" +
                "禁止行为：空话、攻击个人\n" +
                "讨论议题：是否把验证周期压缩到两周？\n" +
                "\n" +
                "请只输出中文正文，不要输出 JSON、Markdown 或任何解释。控制在 180 字以内。"

        const val EXPECTED_ROUND_ONE_USER =
            "议题：是否把验证周期压缩到两周？\n" +
                "\n" +
                "讨论记录：\n" +
                "方案派：先做两周验证\n" +
                "我：预算只有两周\n" +
                "\n" +
                "请基于以上讨论说出你的观点。"

        val EXPECTED_ROUND_TWO_SYSTEM: String =
            "你是圆桌讨论中的「质疑派」，先找漏洞。\n" +
                "你始终是 AI，不得声称自己是真人、公众人物，也不得冒充任何真实个人。\n" +
                "专长：风险\n" +
                "当前目标：质疑\n" +
                "默认立场：谨慎\n" +
                "表达风格：尖锐\n" +
                "讨论议题：是否把验证周期压缩到两周？" +
                "\n\n\n" +
                """
                |现在是第二轮引用式互评。请只返回一个 JSON 对象，不要输出 Markdown 或解释。
                |JSON 必须包含：
                |- message_type：support、challenge、supplement 或 question。
                |- claim：一句话主张，不超过 80 字。
                |- body：中文正文。
                |- stance：必须与 message_type 相同。
                |- reference_message_id：引用候选观点中的一条。
                |- confidence：0 到 1 之间的数字。
                |不得引用自己、用户消息、pass 或候选列表之外的观点。
                |如果没有可引用的有效观点，只输出 PASS。
                |示例：
                |{"message_type":"challenge","claim":"成本被低估","body":"我质疑这个判断，因为注意力也是成本。","stance":"challenge","reference_message_id":"UUID","confidence":0.7}
                """.trimMargin() + "\n"

        const val EXPECTED_ROUND_TWO_USER =
            "议题：是否把验证周期压缩到两周？\n" +
                "\n" +
                "讨论记录：\n" +
                "方案派：先做两周验证\n" +
                "质疑派：我不同意\n" +
                "\n" +
                "可引用的候选观点：\n" +
                "1. author=方案派 agent_id=p1 message_id=m1 主张=先做两周验证\n" +
                "\n" +
                "请引用其中一条，并按要求返回 JSON。"
    }
}
