package com.agentroundtable.app.local

import android.content.Context
import android.net.Uri
import com.agentroundtable.core.local.LocalModel
import com.agentroundtable.core.local.LocalModelCatalog
import com.agentroundtable.core.local.Sha256
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** 模型文件的本地归档。模型文件从不进入 APK 或仓库。 */
interface LocalModelStore {
    fun fileFor(model: LocalModel): File

    fun isVerified(model: LocalModel): Boolean

    /** 下载并校验 SHA256。失败时抛出 [IOException]。 */
    suspend fun download(model: LocalModel, onProgress: (Float) -> Unit): File

    /** 从系统文件选择器导入，按 SHA256 匹配清单；不匹配时返回 null。 */
    suspend fun import(uri: Uri): LocalModel?

    suspend fun verify(model: LocalModel): Boolean
}

class AndroidLocalModelStore(
    private val context: Context,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .followRedirects(true)
        .build(),
) : LocalModelStore {
    private val modelsDir: File
        get() = File(context.filesDir, MODELS_DIR).apply {
            if (!exists()) mkdirs()
        }

    override fun fileFor(model: LocalModel): File = File(modelsDir, model.fileName)

    private fun markerFor(model: LocalModel): File = File(modelsDir, "${model.fileName}.sha256")

    override fun isVerified(model: LocalModel): Boolean {
        val file = fileFor(model)
        if (!file.isFile || file.length() != model.sizeBytes) return false
        val marker = markerFor(model)
        if (!marker.isFile) return false
        return runCatching { marker.readText().trim() }.getOrNull()
            ?.equals(model.sha256, ignoreCase = true) == true
    }

    override suspend fun verify(model: LocalModel): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(model)
        if (!file.isFile) return@withContext false
        if (!Sha256.matches(file, model.sha256)) {
            markerFor(model).delete()
            return@withContext false
        }
        markerFor(model).writeText(model.sha256)
        true
    }

    override suspend fun download(model: LocalModel, onProgress: (Float) -> Unit): File =
        withContext(Dispatchers.IO) {
            modelsDir.mkdirs()
            var lastError: Exception? = null
            for (url in model.downloadUrls) {
                try {
                    return@withContext downloadFrom(model, url, onProgress)
                } catch (error: Exception) {
                    ensureActive()
                    lastError = error
                    markerFor(model).delete()
                }
            }
            throw IOException(
                "模型下载失败：${lastError?.message ?: "所有镜像均不可用"}",
                lastError,
            )
        }

    private suspend fun downloadFrom(
        model: LocalModel,
        url: String,
        onProgress: (Float) -> Unit,
    ): File {
        val target = fileFor(model)
        val part = File(modelsDir, "${model.fileName}.part")
        part.delete()
        val request = Request.Builder().url(url).get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("HTTP ${response.code}")
            }
            val body = response.body
            val total = body.contentLength().takeIf { it > 0 } ?: model.sizeBytes
            var copied = 0L
            var lastReported = 0L
            val digest = MessageDigest.getInstance("SHA-256")
            body.byteStream().use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        copied += read
                        val now = System.nanoTime()
                        if (now - lastReported > PROGRESS_INTERVAL_NANOS) {
                            lastReported = now
                            onProgress((copied.toDouble() / total).toFloat().coerceIn(0f, 1f))
                        }
                    }
                }
            }
            onProgress(1f)
            if (copied != model.sizeBytes) {
                part.delete()
                throw IOException("模型体积不符：期望 ${model.sizeBytes} 字节，实际 $copied 字节")
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (!actual.equals(model.sha256, ignoreCase = true)) {
                part.delete()
                throw IOException("SHA256 校验失败，模型文件可能不完整。")
            }
            if (target.exists()) target.delete()
            if (!part.renameTo(target)) {
                part.delete()
                throw IOException("无法保存模型文件。")
            }
            markerFor(model).writeText(model.sha256)
            target
        }
        return target
    }

    override suspend fun import(uri: Uri): LocalModel? = withContext(Dispatchers.IO) {
        val part = File(modelsDir, "import-${System.currentTimeMillis()}.part")
        val digest = MessageDigest.getInstance("SHA-256")
        var copied = 0L
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        copied += read
                    }
                }
            } ?: return@withContext null

            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            val model = LocalModelCatalog.all.firstOrNull {
                it.sizeBytes == copied && it.sha256.equals(actual, ignoreCase = true)
            } ?: return@withContext null

            val target = fileFor(model)
            if (target.exists()) target.delete()
            if (!part.renameTo(target)) return@withContext null
            markerFor(model).writeText(model.sha256)
            model
        } finally {
            if (part.exists()) part.delete()
        }
    }

    private companion object {
        const val MODELS_DIR = "models"
        const val PROGRESS_INTERVAL_NANOS = 250_000_000L
    }
}
