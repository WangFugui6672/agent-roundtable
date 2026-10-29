package com.agentroundtable.core.api

/** 按队列返回预设响应的传输实现，用于协议层测试。 */
class FakeTransport(
    private val responses: MutableList<HttpResponse> = mutableListOf(),
) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    var throwOnNext: Exception? = null

    fun enqueue(statusCode: Int, body: String) {
        responses += HttpResponse(statusCode, body)
    }

    override suspend fun execute(request: HttpRequest): HttpResponse {
        requests += request
        throwOnNext?.let { error ->
            throwOnNext = null
            throw error
        }
        return responses.removeAt(0)
    }
}
