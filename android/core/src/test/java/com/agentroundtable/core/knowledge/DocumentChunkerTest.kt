package com.agentroundtable.core.knowledge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentChunkerTest {
    @Test
    fun `an empty document produces no chunks`() {
        assertEquals(emptyList<String>(), DocumentChunker.chunk(""))
        assertEquals(emptyList<String>(), DocumentChunker.chunk("  \n\n \t \n"))
        assertEquals(emptyList<String>(), DocumentChunker.chunk("\r\n\r\n"))
    }

    @Test
    fun `a short document produces one chunk`() {
        assertEquals(listOf("只有一个段落。"), DocumentChunker.chunk("只有一个段落。"))
    }

    @Test
    fun `paragraphs are joined with a blank line and packed up to the limit`() {
        val first = "甲".repeat(200)
        val second = "乙".repeat(200)
        val third = "丙".repeat(200)

        val chunks = DocumentChunker.chunk("$first\n\n$second\n\n$third")

        assertEquals(2, chunks.size)
        assertTrue(chunks[0].contains(first))
        assertTrue(chunks[0].contains(second))
        assertTrue(chunks[0].endsWith(second))
        assertTrue(chunks[1].endsWith(third))
        assertEquals(chunks[0].takeLast(50), chunks[1].take(50))
        assertTrue(chunks.all { it.length <= DocumentChunker.MAX_CHUNK_CHARS })
    }

    @Test
    fun `a paragraph that fits is never split across chunks`() {
        val paragraphs = (1..4).map { index -> "第${index}段".repeat(50) }
        val chunks = DocumentChunker.chunk(paragraphs.joinToString("\n\n"))

        paragraphs.forEach { paragraph ->
            assertTrue("paragraph should be intact", chunks.any { it.contains(paragraph) })
        }
    }

    @Test
    fun `a paragraph of exactly the maximum length stays in one chunk`() {
        val chunks = DocumentChunker.chunk("甲".repeat(DocumentChunker.MAX_CHUNK_CHARS))

        assertEquals(1, chunks.size)
        assertEquals(DocumentChunker.MAX_CHUNK_CHARS, chunks.single().length)
    }

    @Test
    fun `an oversized paragraph is split at sentence endings`() {
        val sentence = "这是一个完整的句子。"
        val chunks = DocumentChunker.chunk(sentence.repeat(80))

        assertEquals(2, chunks.size)
        assertTrue(chunks.all { it.length <= DocumentChunker.MAX_CHUNK_CHARS })
        assertTrue(chunks[0].endsWith(sentence))
        assertTrue(chunks[1].endsWith(sentence))
        assertEquals(chunks[0].takeLast(50), chunks[1].take(50))
    }

    @Test
    fun `a sentence longer than the limit is hard split without losing text`() {
        val text = "甲".repeat(1100)
        val chunks = DocumentChunker.chunk(text)

        assertTrue(chunks.size > 1)
        assertTrue(chunks.all { it.length <= DocumentChunker.MAX_CHUNK_CHARS })
        assertEquals(
            text.length,
            chunks.sumOf { it.length } - DocumentChunker.OVERLAP_CHARS * (chunks.size - 1),
        )
    }

    @Test
    fun `adjacent chunks overlap by exactly fifty characters`() {
        val chunks = DocumentChunker.chunk("乙".repeat(1500))

        assertTrue(chunks.size >= 3)
        chunks.zipWithNext().forEach { (previous, next) ->
            assertEquals(
                previous.takeLast(DocumentChunker.OVERLAP_CHARS),
                next.take(DocumentChunker.OVERLAP_CHARS),
            )
        }
    }

    @Test
    fun `overlap is only counted once when measuring new content`() {
        val text = "丙".repeat(1100)
        val chunks = DocumentChunker.chunk(text)

        val novelChars = chunks.first().length +
            chunks.drop(1).sumOf { it.length - DocumentChunker.OVERLAP_CHARS }
        assertEquals(text.length, novelChars)
    }

    @Test
    fun `a single sentence of exactly the maximum length is one chunk`() {
        val sentence = "丁".repeat(DocumentChunker.MAX_CHUNK_CHARS - 1) + "。"
        val chunks = DocumentChunker.chunk(sentence)

        assertEquals(1, chunks.size)
        assertEquals(DocumentChunker.MAX_CHUNK_CHARS, chunks.single().length)
    }

    @Test
    fun `windows line endings are normalized and blank lines collapse`() {
        val chunks = DocumentChunker.chunk("第一段。\r\n\r\n\r\n第二段。")

        assertEquals(listOf("第一段。\n\n第二段。"), chunks)
    }

    @Test
    fun `english sentences keep a single separating space`() {
        val chunks = DocumentChunker.chunk("First sentence. Second sentence. Third sentence.")
        val expected = "First sentence. Second sentence. Third sentence."

        assertEquals(listOf(expected), chunks)
    }
}
