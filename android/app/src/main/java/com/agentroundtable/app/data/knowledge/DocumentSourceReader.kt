package com.agentroundtable.app.data.knowledge

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.agentroundtable.core.knowledge.ImportSource
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 从系统文件选择器返回的 URI 读取文档。
 *
 * 读取在 IO 线程完成；直接拒绝超大文件，避免把整份内容读进内存后才失败。
 */
interface DocumentSourceReader {
    suspend fun read(sourceId: String): ImportSource
}

/** 无法读取所选文件时的明确错误。 */
class DocumentReadException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

class ContentResolverDocumentSourceReader(context: Context) : DocumentSourceReader {
    private val resolver = context.applicationContext.contentResolver

    override suspend fun read(sourceId: String): ImportSource = withContext(Dispatchers.IO) {
        val uri = try {
            Uri.parse(sourceId)
        } catch (error: Exception) {
            throw DocumentReadException("无法识别所选文件。", error)
        }
        try {
            val name = displayName(uri) ?: "未命名文档"
            val mimeType = resolver.getType(uri)
            val stream = resolver.openInputStream(uri)
                ?: throw DocumentReadException("无法打开所选文件。")
            val bytes = stream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_DOCUMENT_BYTES) {
                        throw DocumentReadException("文件超过 20 MB，暂时无法导入。")
                    }
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            }
            ImportSource(name = name, mimeType = mimeType, bytes = bytes)
        } catch (error: DocumentReadException) {
            throw error
        } catch (error: IOException) {
            throw DocumentReadException("读取文件失败：${error.message ?: "未知错误"}", error)
        } catch (error: SecurityException) {
            throw DocumentReadException("没有读取该文件的权限。", error)
        }
    }

    private fun displayName(uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (error: Exception) {
        null
    }?.takeIf { it.isNotBlank() }

    private companion object {
        const val MAX_DOCUMENT_BYTES = 20 * 1024 * 1024
    }
}
