package com.agentroundtable.app.data.knowledge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class BertTokenizerTest {
    private val tokenizer = BertTokenizer(
        listOf(
            "[PAD]",
            "[UNK]",
            "[CLS]",
            "[SEP]",
            "[MASK]",
            "你",
            "好",
            "世",
            "界",
            "hello",
            "##world",
            "world",
            "Hello",
            ",",
            "，",
        ),
    )

    @Test
    fun `中文按字切分并添加 CLS 与 SEP`() {
        val encoded = tokenizer.encode("你好世界")

        assertArrayEquals(longArrayOf(2, 5, 6, 7, 8, 3), encoded.inputIds)
        assertArrayEquals(LongArray(encoded.length) { 1L }, encoded.attentionMask)
        assertArrayEquals(LongArray(encoded.length), encoded.tokenTypeIds)
    }

    @Test
    fun `英文使用 WordPiece 且不转小写`() {
        assertArrayEquals(longArrayOf(2, 9, 10, 3), tokenizer.encode("helloworld").inputIds)
        assertArrayEquals(longArrayOf(2, 12, 3), tokenizer.encode("Hello").inputIds)
    }

    @Test
    fun `未知字符回退为 UNK`() {
        assertArrayEquals(longArrayOf(2, 5, 6, 1, 3), tokenizer.encode("你好吗").inputIds)
    }

    @Test
    fun `ASCII 标点与中文标点单独成词`() {
        assertArrayEquals(longArrayOf(2, 9, 13, 11, 3), tokenizer.encode("hello,world").inputIds)
        assertArrayEquals(
            longArrayOf(2, 5, 6, 14, 7, 8, 3),
            tokenizer.encode("你好，世界").inputIds,
        )
    }

    @Test
    fun `空文本只包含 CLS 与 SEP`() {
        assertArrayEquals(longArrayOf(2, 3), tokenizer.encode("").inputIds)
    }

    @Test
    fun `超过最大长度时截断到 512 个 token`() {
        val encoded = tokenizer.encode("你".repeat(600))

        assertEquals(512, encoded.length)
        assertEquals(2L, encoded.inputIds.first())
        assertEquals(3L, encoded.inputIds.last())
        assertEquals(5L, encoded.inputIds[1])
        assertEquals(5L, encoded.inputIds[encoded.inputIds.lastIndex - 1])
    }

    @Test
    fun `maxLength 参数限制内容长度`() {
        assertArrayEquals(longArrayOf(2, 5, 6, 3), tokenizer.encode("你好世界", maxLength = 4).inputIds)
    }
}
