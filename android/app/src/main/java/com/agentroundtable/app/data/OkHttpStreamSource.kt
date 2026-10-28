package com.agentroundtable.app.data

import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.turn.StreamSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** 用 OkHttp 逐行读取 Provider 的 SSE 响应。 */
class OkHttpStreamSource(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build(),
) : StreamSource {
    override fun open(request: HttpRequest): Flow<String> = flow {
        val body = request.body?.toRequestBody(JSON) ?: ByteArray(0).toRequestBody(JSON)
        val raw = Request.Builder()
            .url(request.url)
            .apply {
                request.headers.forEach { (name, value) -> header(name, value) }
                method(request.method, body)
            }
            .build()

        client.newCall(raw).execute().use { response ->
            if (!response.isSuccessful) return@use
            val source = response.body?.source() ?: return@use
            while (!source.exhausted()) {
                emit(source.readUtf8Line() ?: break)
            }
        }
    }.flowOn(Dispatchers.IO)

    private companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
