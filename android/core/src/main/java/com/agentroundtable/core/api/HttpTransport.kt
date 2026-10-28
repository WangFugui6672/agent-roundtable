package com.agentroundtable.core.api

/** 一次 HTTP 请求的最小描述。 */
data class HttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
)

/** 一次 HTTP 响应。 */
data class HttpResponse(
    val statusCode: Int,
    val body: String,
)

/**
 * HTTP 传输接缝。
 *
 * 真实实现走 OkHttp；测试用内存实现，从而让协议层在纯 JVM 上可测。
 */
fun interface HttpTransport {
    suspend fun execute(request: HttpRequest): HttpResponse
}
