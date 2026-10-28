package com.agentroundtable.app.data.knowledge

import android.content.Context
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.DocumentParseException
import com.agentroundtable.core.knowledge.DocumentParser
import com.agentroundtable.core.knowledge.IncomingDocument
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Android 侧的文档文本抽取。
 *
 * PDF 使用纯 Java 的 `pdfbox-android`（Apache License 2.0），没有 AWT 依赖；
 * TXT / Markdown 直接解码文本。所有工作都在 IO 线程执行，不阻塞界面。
 */
class AndroidDocumentParser(context: Context) : DocumentParser {
    init {
        if (!PDFBoxResourceLoader.isReady()) {
            PDFBoxResourceLoader.init(context.applicationContext)
        }
    }

    override suspend fun extract(document: IncomingDocument): String = withContext(Dispatchers.IO) {
        when (document.format) {
            DocumentFormat.Pdf -> extractPdf(document)
            DocumentFormat.Txt, DocumentFormat.Markdown -> decodePlainText(document)
        }
    }

    private fun extractPdf(document: IncomingDocument): String {
        if (document.bytes.size > MAX_DOCUMENT_BYTES) {
            throw DocumentParseException("文件超过 20 MB，暂时无法解析。")
        }
        val text = try {
            PDDocument.load(document.bytes).use { pdf ->
                PDFTextStripper().getText(pdf)
            }
        } catch (error: InvalidPasswordException) {
            throw DocumentParseException("PDF 已加密，无法提取文本。", error)
        } catch (error: IOException) {
            throw DocumentParseException("无法读取 PDF：文件可能已损坏或不是有效的 PDF。", error)
        } catch (error: RuntimeException) {
            throw DocumentParseException("解析 PDF 失败：${error.message ?: "未知错误"}", error)
        }
        return text
    }

    private fun decodePlainText(document: IncomingDocument): String {
        val bytes = document.bytes
        return when {
            bytes.startsWith(UTF8_BOM) -> String(bytes, 3, bytes.size - 3, StandardCharsets.UTF_8)
            bytes.startsWith(UTF16_LE_BOM) ->
                String(bytes, 2, bytes.size - 2, StandardCharsets.UTF_16LE)
            bytes.startsWith(UTF16_BE_BOM) ->
                String(bytes, 2, bytes.size - 2, StandardCharsets.UTF_16BE)
            else -> decodeWithoutBom(bytes)
        }
    }

    private fun decodeWithoutBom(bytes: ByteArray): String {
        // UTF-16 无 BOM 的 ASCII/中文文本通常每隔一个字节就是 0。
        val sample = bytes.copyOfRange(0, minOf(bytes.size, 100))
        if (sample.isNotEmpty() && sample.count { it == 0.toByte() } > sample.size / 4) {
            decodeStrict(bytes, StandardCharsets.UTF_16LE)?.let { return it }
            decodeStrict(bytes, StandardCharsets.UTF_16BE)?.let { return it }
        }
        decodeStrict(bytes, StandardCharsets.UTF_8)?.let { return it }
        decodeStrict(bytes, Charset.forName("GB18030"))?.let { return it }
        throw DocumentParseException("无法识别文本编码，请使用 UTF-8 或 GB18030 编码后重试。")
    }

    private fun decodeStrict(bytes: ByteArray, charset: Charset): String? {
        val decoder = charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (error: CharacterCodingException) {
            null
        }
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        return prefix.indices.all { this[it] == prefix[it] }
    }

    private companion object {
        const val MAX_DOCUMENT_BYTES = 20 * 1024 * 1024
        val UTF8_BOM = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val UTF16_LE_BOM = byteArrayOf(0xFF.toByte(), 0xFE.toByte())
        val UTF16_BE_BOM = byteArrayOf(0xFE.toByte(), 0xFF.toByte())
    }
}
