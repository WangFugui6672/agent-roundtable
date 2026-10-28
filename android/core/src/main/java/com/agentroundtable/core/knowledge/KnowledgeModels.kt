package com.agentroundtable.core.knowledge

/**
 * 资料库支持的文档格式。
 *
 * DOCX 刻意不支持：解析 `.docx` 需要额外的 OOXML 组件，而本期只引入纯 Java 的
 * PDF 文本抽取；需要把 Word 文档另存为 PDF、TXT 或 Markdown 后再导入。
 * 原因同时展示在资料库界面与 `android/README.md`。
 */
enum class DocumentFormat(val wireValue: String, val displayName: String) {
    Pdf("pdf", "PDF"),
    Txt("txt", "TXT"),
    Markdown("markdown", "Markdown"),
    ;

    companion object {
        const val DOCX_MIME_TYPE =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        const val DOCX_UNSUPPORTED_REASON =
            "DOCX 暂不支持：解析 .docx 需要额外的 OOXML 组件。请先另存为 PDF、TXT 或 Markdown 再导入。"

        /** 系统文件选择器只展示资料库能处理的格式。 */
        val pickerMimeTypes: Array<String> = arrayOf(
            "application/pdf",
            "text/plain",
            "text/markdown",
            "text/x-markdown",
        )

        fun fromWire(value: String): DocumentFormat? =
            entries.firstOrNull { it.wireValue == value }

        /**
         * 按文件名后缀识别格式；后缀未知时再参考 MIME。
         *
         * 后缀优先：部分文件提供方会把 `.md` 报成 `text/plain`，此时仍按 Markdown 展示。
         */
        fun detect(fileName: String, mimeType: String?): DocumentFormat? {
            val extension = fileName.substringAfterLast('.', "").lowercase()
            when (extension) {
                "pdf" -> return Pdf
                "txt" -> return Txt
                "md", "markdown" -> return Markdown
            }
            val mime = mimeType?.substringBefore(';')?.trim()?.lowercase()
            return when (mime) {
                "application/pdf" -> Pdf
                "text/plain" -> Txt
                "text/markdown", "text/x-markdown" -> Markdown
                else -> null
            }
        }
    }
}

/** 系统文件选择器返回的原始文档。内容只在本机内存与本地数据库中流转。 */
data class ImportSource(
    val name: String,
    val mimeType: String?,
    val bytes: ByteArray,
)

/** 交给 [DocumentParser] 的文档；格式已经识别，解析器不必再次猜后缀。 */
data class IncomingDocument(
    val name: String,
    val format: DocumentFormat,
    val bytes: ByteArray,
)

/** 资料库中的一篇文档。 */
data class KnowledgeDocument(
    val id: String,
    val name: String,
    val format: DocumentFormat,
    val chunkCount: Int,
    val importedAt: Long,
)

/**
 * 文档块：文档被切分后的最小检索单元。
 *
 * [index] 是该文档块在来源文档内的顺序位置。
 */
data class DocumentChunk(
    val documentId: String,
    val index: Int,
    val text: String,
)

/** 一次导入的结果。失败时不写入任何文档或文档块。 */
sealed interface ImportResult {
    data class Imported(val document: KnowledgeDocument) : ImportResult

    data class Failed(val message: String) : ImportResult
}
