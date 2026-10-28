package com.agentroundtable.app.data

import com.agentroundtable.core.api.HttpRequest
import com.agentroundtable.core.api.HttpResponse
import com.agentroundtable.core.api.HttpTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** 走 OkHttp 的传输实现。所有阻塞调用都切到 IO 调度器。 */
class OkHttpTransport(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build(),
) : HttpTransport {
    override suspend fun execute(request: HttpRequest): HttpResponse = withContext(Dispatchers.IO) {
        // OkHttp 要求 POST/PUT/PATCH 必须带请求体；协议中确有不需要请求体的接口
        // （例如创建匿名会话），因此统一用空体补足，而不是按接口逐个特判。
        val requiresBody = request.method in setOf("POST", "PUT", "PATCH")
        val rawBody = request.body
        val body = when {
            rawBody != null -> rawBody.toRequestBody(JSON_MEDIA_TYPE)
            requiresBody -> ByteArray(0).toRequestBody(JSON_MEDIA_TYPE)
            else -> null
        }
        val rawRequest = Request.Builder()
            .url(request.url)
            .apply {
                request.headers.forEach { (name, value) -> header(name, value) }
                method(request.method, body)
            }
            .build()

        client.newCall(rawRequest).execute().use { response ->
            HttpResponse(
                statusCode = response.code,
                body = response.body?.string().orEmpty(),
            )
        }
    }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}
