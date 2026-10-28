package com.agentroundtable.core.knowledge

import java.util.UUID
import kotlinx.coroutines.CancellationException

/**
 * 资料库导入用例。
 *
 * 导入流程：识别格式 → 抽取文本 → 切分文档块 → 原子写入 [DocumentStore]。
 * 任一步失败都返回 [ImportResult.Failed]，不写入任何文档或文档块。
 *
 * 资料库完全本地：这里没有任何网络依赖，文档内容不会离开设备。
 */
class KnowledgeBase(
    private val parser: DocumentParser,
    private val store: DocumentStore,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val idGenerator: () -> String = { UUID.randomUUID().toString() },
) {
    suspend fun import(source: ImportSource): ImportResult {
        val name = source.name.trim().ifEmpty { UNTITLED_DOCUMENT }
        val format = DocumentFormat.detect(name, source.mimeType)
            ?: return ImportResult.Failed(unsupportedMessage(name, source.mimeType))

        if (source.bytes.isEmpty()) {
            return ImportResult.Failed("文件为空，没有可导入的内容。")
        }

        val text = try {
            parser.extract(IncomingDocument(name = name, format = format, bytes = source.bytes))
        } catch (error: CancellationException) {
            throw error
        } catch (error: DocumentParseException) {
            return ImportResult.Failed(error.message ?: "无法解析这份文档。")
        } catch (error: Exception) {
            return ImportResult.Failed("解析文档失败：${error.message ?: UNKNOWN_ERROR}")
        }

        val chunkTexts = DocumentChunker.chunk(text)
        if (chunkTexts.isEmpty()) {
            return ImportResult.Failed("文档中没有可提取的文本。")
        }

        val documentId = idGenerator()
        val document = KnowledgeDocument(
            id = documentId,
            name = name,
            format = format,
            chunkCount = chunkTexts.size,
            importedAt = clock(),
        )
        val chunks = chunkTexts.mapIndexed { index, chunkText ->
            DocumentChunk(documentId = documentId, index = index, text = chunkText)
        }

        return try {
            store.addDocument(document, chunks)
            ImportResult.Imported(document)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            ImportResult.Failed("保存资料失败，请重试。")
        }
    }

    suspend fun documents(): List<KnowledgeDocument> = store.listDocuments()

    suspend fun chunks(documentId: String): List<DocumentChunk> = store.listChunks(documentId)

    /** 删除文档时由存储实现级联删除全部文档块。 */
    suspend fun delete(documentId: String) = store.deleteDocument(documentId)

    private fun unsupportedMessage(fileName: String, mimeType: String?): String {
        val extension = fileName.substringAfterLast('.', "").lowercase()
        val mime = mimeType?.substringBefore(';')?.trim()?.lowercase()
        return if (extension == "docx" || mime == DocumentFormat.DOCX_MIME_TYPE) {
            DocumentFormat.DOCX_UNSUPPORTED_REASON
        } else {
            "不支持的文件格式，请选择 PDF、TXT 或 Markdown 文档。"
        }
    }

    private companion object {
        const val UNTITLED_DOCUMENT = "未命名文档"
        const val UNKNOWN_ERROR = "未知错误"
    }
}
