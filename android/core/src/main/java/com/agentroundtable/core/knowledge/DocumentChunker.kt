package com.agentroundtable.core.knowledge

/**
 * 文档块切分器。
 *
 * `chunk` 是纯函数：相同文本总是得到相同结果，不依赖时间、随机数或 Android 框架。
 *
 * 规则：
 * 1. 空文档不产生文档块。
 * 2. 优先以空行为段落边界；能放进一个块的相邻段落会合并。
 * 3. 单个段落超过 [MAX_CHUNK_CHARS] 时先按句末标点切分；单句仍超长时按上限硬切。
 * 4. 每个文档块最多 [MAX_CHUNK_CHARS] 个字符。
 * 5. 相邻文档块重叠 [OVERLAP_CHARS] 个字符；第一块没有重叠。
 *
 * 字符数使用 Kotlin `String.length`（UTF-16 代码单元），与检索端的计数保持一致。
 */
object DocumentChunker {
    const val MAX_CHUNK_CHARS = 500
    const val OVERLAP_CHARS = 50

    private const val PARAGRAPH_SEPARATOR = "\n\n"
    private const val SENTENCE_SEPARATOR = " "

    private val paragraphBreak = Regex("\\n[ \\t]*\\n")
    private val sentenceTerminators = setOf('。', '！', '？', '!', '?', '；', ';', '…')
    private val sentenceClosers = setOf('”', '’', '」', '』', '）', ')', '】', ']', '》', '〉', '"', '\'')

    fun chunk(text: String): List<String> {
        val units = buildUnits(text)
        if (units.isEmpty()) return emptyList()

        val pending = ArrayDeque(units)
        val chunks = mutableListOf<String>()
        while (pending.isNotEmpty()) {
            val previous = chunks.lastOrNull()
            val overlap = previous?.let { lastChars(it, OVERLAP_CHARS) }.orEmpty()
            val capacity = MAX_CHUNK_CHARS - overlap.length
            val content = StringBuilder()
            var hasContent = false

            while (pending.isNotEmpty()) {
                val unit = pending.first()
                // 重叠区之后紧接新内容时仍补上分隔符，避免段落或句子粘连。
                val separator = if (hasContent || overlap.isNotEmpty()) unit.separator else ""
                val remaining = capacity - content.length - separator.length
                if (remaining <= 0) break

                if (unit.text.length <= remaining) {
                    content.append(separator).append(unit.text)
                    hasContent = true
                    pending.removeFirst()
                    continue
                }
                if (hasContent) break

                // 只有重叠区时，必须切开当前单元，保证单块不超过上限。
                val split = splitUnit(unit, remaining)
                content.append(separator).append(split.head)
                hasContent = true
                pending.removeFirst()
                if (split.tail.isNotEmpty()) {
                    pending.addFirst(Unit(split.tail, split.tailSeparator))
                }
                break
            }

            // hasContent 为 false 说明连一个字符都放不下；继续循环只会死循环。
            if (!hasContent) break
            chunks += overlap + content
        }
        return chunks
    }

    private fun buildUnits(text: String): List<Unit> {
        val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
        val paragraphs = normalized.split(paragraphBreak)
            .map { it.trim() }
            .filter { it.isNotEmpty() }

        val units = mutableListOf<Unit>()
        for (paragraph in paragraphs) {
            if (paragraph.length <= MAX_CHUNK_CHARS) {
                units += Unit(paragraph, PARAGRAPH_SEPARATOR)
            } else {
                units += sentenceUnits(paragraph)
            }
        }
        return units
    }

    /**
     * 把一个超长段落拆成不超过上限的句子组。
     *
     * 每个单元记录「接在已有内容之后时应补的分隔符」：段落之间是两个换行，
     * 原文本里句子之间的空白规范成一个空格，中文句末没有空白时保持紧凑。
     */
    private fun sentenceUnits(paragraph: String): List<Unit> {
        val sentences = splitSentences(paragraph)
        if (sentences.isEmpty()) return listOf(Unit(paragraph, PARAGRAPH_SEPARATOR))

        val units = mutableListOf<Unit>()
        val current = StringBuilder()
        var groupSeparator = PARAGRAPH_SEPARATOR
        var separatorBeforeNext = PARAGRAPH_SEPARATOR

        fun flush() {
            if (current.isEmpty()) return
            units += Unit(current.toString(), groupSeparator)
            current.clear()
        }

        for (sentence in sentences) {
            if (sentence.text.length > MAX_CHUNK_CHARS) {
                flush()
                var partSeparator = separatorBeforeNext
                hardSplit(sentence.text).forEach { part ->
                    units += Unit(part, partSeparator)
                    partSeparator = ""
                }
                separatorBeforeNext = sentence.separatorAfter
                continue
            }

            if (current.isEmpty()) {
                groupSeparator = separatorBeforeNext
                current.append(sentence.text)
            } else if (current.length + separatorBeforeNext.length +
                sentence.text.length <= MAX_CHUNK_CHARS
            ) {
                current.append(separatorBeforeNext).append(sentence.text)
            } else {
                flush()
                groupSeparator = separatorBeforeNext
                current.append(sentence.text)
            }
            separatorBeforeNext = sentence.separatorAfter
        }
        flush()
        return units
    }

    private data class Sentence(val text: String, val separatorAfter: String)

    private fun splitSentences(paragraph: String): List<Sentence> {
        val sentences = mutableListOf<Sentence>()
        var start = 0
        var index = 0
        while (index < paragraph.length) {
            val char = paragraph[index]
            val terminates = char in sentenceTerminators ||
                (char == '.' && (index + 1 == paragraph.length || paragraph[index + 1].isWhitespace()))
            if (!terminates) {
                index++
                continue
            }

            var end = index + 1
            while (end < paragraph.length && paragraph[end] in sentenceClosers) end++
            val text = paragraph.substring(start, end).trim()
            var next = end
            while (next < paragraph.length && paragraph[next].isWhitespace()) next++
            val hasWhitespace = next > end
            if (text.isNotEmpty()) {
                sentences += Sentence(text, if (hasWhitespace) SENTENCE_SEPARATOR else "")
            }
            start = next
            index = next
        }

        if (start < paragraph.length) {
            val rest = paragraph.substring(start).trim()
            if (rest.isNotEmpty()) sentences += Sentence(rest, "")
        }
        return sentences
    }

    private data class Unit(val text: String, val separator: String)

    private data class Split(val head: String, val tail: String, val tailSeparator: String)

    /**
     * 把一个放不进当前剩余空间的单元切开。
     *
     * 优先在句子边界切，其次在空白处切；都没有时按容量硬切，但不会把一个
     * UTF-16 代理对从中间切开。
     */
    private fun splitUnit(unit: Unit, capacity: Int): Split {
        val text = unit.text
        require(capacity in 1 until text.length) { "capacity must split the unit" }
        val boundary = preferredBoundary(text, capacity)
        val head = text.substring(0, boundary.index).trimEnd()
        val tail = text.substring(boundary.index).trimStart()
        val tailSeparator = if (boundary.kind == BoundaryKind.Hard) "" else SENTENCE_SEPARATOR
        return Split(head, tail, tailSeparator)
    }

    private data class Boundary(val index: Int, val kind: BoundaryKind)

    private enum class BoundaryKind { Sentence, Whitespace, Hard }

    private fun preferredBoundary(text: String, capacity: Int): Boundary {
        val floor = capacity / 2
        var index = capacity
        while (index > floor) {
            if (endsSentence(text, index)) return Boundary(index, BoundaryKind.Sentence)
            index--
        }

        index = capacity
        while (index > floor) {
            if (text[index - 1].isWhitespace()) return Boundary(index, BoundaryKind.Whitespace)
            index--
        }
        return Boundary(safeCut(text, capacity), BoundaryKind.Hard)
    }

    private fun endsSentence(text: String, end: Int): Boolean {
        var index = end - 1
        while (index >= 0 && text[index] in sentenceClosers) index--
        if (index < 0) return false
        val char = text[index]
        return char in sentenceTerminators ||
            (char == '.' && (index + 1 == text.length || text[index + 1].isWhitespace()))
    }

    private fun safeCut(text: String, capacity: Int): Int {
        var cut = capacity
        if (cut in 1 until text.length &&
            text[cut - 1].isHighSurrogate() &&
            text[cut].isLowSurrogate()
        ) {
            cut--
        }
        return cut.coerceAtLeast(1)
    }

    private fun hardSplit(text: String): List<String> {
        val parts = mutableListOf<String>()
        var start = 0
        while (start < text.length) {
            val cut = safeCut(text, minOf(MAX_CHUNK_CHARS, text.length - start))
            val end = start + cut
            parts += text.substring(start, end)
            start = end
        }
        return parts
    }

    /** 取末尾 [count] 个字符，且不把代理对拆开。 */
    private fun lastChars(value: String, count: Int): String {
        if (value.length <= count) return value
        var start = value.length - count
        if (start > 0 && value[start].isLowSurrogate()) start++
        return value.substring(start)
    }
}
