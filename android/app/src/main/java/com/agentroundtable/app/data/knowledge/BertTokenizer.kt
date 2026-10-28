package com.agentroundtable.app.data.knowledge

/** 一条文本编码后的 BERT 输入。 */
data class EncodedText(
    val inputIds: LongArray,
    val attentionMask: LongArray,
    val tokenTypeIds: LongArray,
) {
    val length: Int get() = inputIds.size
}

/**
 * BERT WordPiece 分词器。
 *
 * 按 `bge-small-zh-v1.5` 的 `tokenizer_config.json` 实现：
 * `do_lower_case = false`、`do_basic_tokenize = true`、`tokenize_chinese_chars = true`。
 * 中文逐字切分，ASCII 标点单独成词，未知词回退为 `[UNK]`，最长 512 个 token。
 *
 * 纯 JVM 实现，可在 `:app` 的单元测试中验证，不需要 Android 或真实模型。
 */
class BertTokenizer(vocab: List<String>) {
    private val idsByToken: Map<String, Int> =
        vocab.withIndex().associate { (index, token) -> token to index }
    private val clsId: Int = tokenId(CLS_TOKEN)
    private val sepId: Int = tokenId(SEP_TOKEN)
    private val unkId: Int = tokenId(UNK_TOKEN)

    fun encode(text: String, maxLength: Int = MAX_LENGTH): EncodedText {
        val limit = maxLength.coerceIn(2, MAX_LENGTH)
        val contentLimit = limit - 2
        val content = ArrayList<Int>(minOf(text.length, contentLimit))

        outer@ for (word in basicTokenize(text)) {
            for (piece in wordPieces(word)) {
                if (content.size >= contentLimit) break@outer
                content += idsByToken[piece] ?: unkId
            }
        }

        val inputIds = LongArray(content.size + 2)
        inputIds[0] = clsId.toLong()
        for (index in content.indices) {
            inputIds[index + 1] = content[index].toLong()
        }
        inputIds[inputIds.lastIndex] = sepId.toLong()

        return EncodedText(
            inputIds = inputIds,
            attentionMask = LongArray(inputIds.size) { 1L },
            tokenTypeIds = LongArray(inputIds.size),
        )
    }

    private fun tokenId(token: String): Int =
        idsByToken[token] ?: error("vocabulary is missing required token $token")

    private fun basicTokenize(text: String): List<String> {
        val cleaned = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            when {
                codePoint == 0 || codePoint == REPLACEMENT_CHARACTER -> Unit
                Character.isISOControl(codePoint) -> Unit
                Character.isWhitespace(codePoint) -> cleaned.append(' ')
                else -> cleaned.appendCodePoint(codePoint)
            }
            index += Character.charCount(codePoint)
        }

        val spaced = StringBuilder(cleaned.length + 8)
        index = 0
        while (index < cleaned.length) {
            val codePoint = cleaned.codePointAt(index)
            if (isChineseCodePoint(codePoint)) {
                spaced.append(' ').appendCodePoint(codePoint).append(' ')
            } else {
                spaced.appendCodePoint(codePoint)
            }
            index += Character.charCount(codePoint)
        }

        val words = mutableListOf<String>()
        for (word in spaced.split(' ')) {
            if (word.isEmpty()) continue
            val current = StringBuilder()
            for (char in word) {
                if (isPunctuation(char.code)) {
                    if (current.isNotEmpty()) {
                        words += current.toString()
                        current.clear()
                    }
                    words += char.toString()
                } else {
                    current.append(char)
                }
            }
            if (current.isNotEmpty()) words += current.toString()
        }
        return words
    }

    private fun wordPieces(word: String): List<String> {
        if (word.length > MAX_CHARS_PER_WORD) return listOf(UNK_TOKEN)

        val pieces = mutableListOf<String>()
        var start = 0
        while (start < word.length) {
            var end = word.length
            var match: String? = null
            while (start < end) {
                val candidate = if (start > 0) {
                    "##" + word.substring(start, end)
                } else {
                    word.substring(start, end)
                }
                if (idsByToken.containsKey(candidate)) {
                    match = candidate
                    break
                }
                end--
            }
            if (match == null) return listOf(UNK_TOKEN)
            pieces += match
            start = end
        }
        return pieces
    }

    private fun isChineseCodePoint(codePoint: Int): Boolean =
        codePoint in 0x4E00..0x9FFF ||
            codePoint in 0x3400..0x4DBF ||
            codePoint in 0x20000..0x2A6DF ||
            codePoint in 0x2A700..0x2B73F ||
            codePoint in 0x2B740..0x2B81F ||
            codePoint in 0x2B820..0x2CEAF ||
            codePoint in 0xF900..0xFAFF ||
            codePoint in 0x2F800..0x2FA1F

    /** BERT 只把 ASCII 标点拆开；中文标点由中文字符切分后自然独立。 */
    private fun isPunctuation(codePoint: Int): Boolean =
        codePoint in 33..47 ||
            codePoint in 58..64 ||
            codePoint in 91..96 ||
            codePoint in 123..126

    private companion object {
        const val CLS_TOKEN = "[CLS]"
        const val SEP_TOKEN = "[SEP]"
        const val UNK_TOKEN = "[UNK]"
        const val REPLACEMENT_CHARACTER = 0xFFFD
        const val MAX_CHARS_PER_WORD = 100
        const val MAX_LENGTH = 512
    }
}
