package com.agentroundtable.core.knowledge

/**
 * 文档文本抽取接缝。
 *
 * PDF 需要 Android 侧的 PDFBox，因此实现放在 `:app`，通过构造参数注入给
 * [KnowledgeBase]；`:core` 的单测使用可预测的假实现。
 */
fun interface DocumentParser {
    /** 抽取纯文本；无法解析时抛出 [DocumentParseException]，异常消息面向用户。 */
    suspend fun extract(document: IncomingDocument): String
}

/** 文档无法解析时的明确错误；消息可直接展示给用户。 */
class DocumentParseException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
