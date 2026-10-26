import Foundation

/// Streaming transport seam. Tests inject recorded SSE lines; production uses
/// `URLSession`'s byte stream. Keeping this separate from `HTTPTransport` avoids
/// buffering the whole response, which would defeat streaming.
public struct StreamingResponse: Sendable {
    public let statusCode: Int
    public let lines: AsyncThrowingStream<String, Error>

    public init(statusCode: Int, lines: AsyncThrowingStream<String, Error>) {
        self.statusCode = statusCode
        self.lines = lines
    }
}

public protocol LineStreaming: Sendable {
    func stream(_ request: URLRequest) async throws -> StreamingResponse
}

public struct URLSessionLineStream: LineStreaming {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: URLRequest) async throws -> StreamingResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(statusCode: statusCode, lines: lines)
    }
}

/// Errors the provider itself reports. Never swapped or retried silently
/// (PRD 7.13: 不静默切换模型).
public enum ProviderError: Error, Equatable, Sendable {
    case http(status: Int, detail: String)
    case invalidResponse(String)
    case emptyReply
    case timeout
    case transport(String)

    public var failureCode: String {
        switch self {
        case let .http(status, _):
            switch status {
            case 401, 403: return "provider_unauthorized"
            case 402: return "provider_insufficient_balance"
            case 404: return "provider_model_not_found"
            case 429: return "provider_rate_limited"
            case 500...: return "provider_server_error"
            default: return "provider_error"
            }
        case .invalidResponse: return "provider_invalid_response"
        case .emptyReply: return "provider_empty_reply"
        case .timeout: return "provider_timeout"
        case .transport: return "provider_network"
        }
    }

    public var retryable: Bool {
        switch self {
        case let .http(status, _):
            return status == 429 || status >= 500
        case .invalidResponse, .emptyReply, .timeout, .transport:
            return true
        }
    }

    public var message: String {
        switch self {
        case let .http(status, detail):
            switch status {
            case 401, 403:
                return "API Key 无效或没有访问权限（HTTP \(status)）。"
            case 402:
                return "Provider 余额不足或计费方式未开通（HTTP 402）。"
            case 404:
                return "Provider 接口不存在（HTTP 404），请检查 BaseURL 是否以 /v1 结尾。"
            case 429:
                return "Provider 限流，请稍后重试（HTTP 429）。"
            default:
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Provider 返回 HTTP \(status)。"
                    : "Provider 返回 HTTP \(status)：\(String(trimmed.prefix(200)))"
            }
        case let .invalidResponse(reason):
            return "Provider 响应格式不正确：\(reason)"
        case .emptyReply:
            return "Provider 返回了空内容。"
        case .timeout:
            return "请求超时（60 秒），Provider 可能繁忙或网络不稳定。"
        case let .transport(reason):
            return "网络请求失败：\(reason)"
        }
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public enum ProviderStreamEvent: Equatable, Sendable {
    case delta(String)
    case usage(ProviderUsage)
    case completed(finishReason: String?)
}

/// OpenAI-compatible chat client with SSE streaming.
public struct ProviderChatClient: Sendable {
    private let streaming: LineStreaming

    public init(streaming: LineStreaming = URLSessionLineStream()) {
        self.streaming = streaming
    }

    public func stream(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        maxTokens: Int = 400
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in streamEvents(
                        configuration: configuration,
                        apiKey: apiKey,
                        messages: messages,
                        maxTokens: maxTokens
                    ) {
                        if case let .delta(delta) = event {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func streamEvents(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        maxTokens: Int = 400
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(
                        configuration: configuration,
                        apiKey: apiKey,
                        messages: messages,
                        maxTokens: maxTokens
                    )
                    let response = try await streaming.stream(request)
                    guard (200 ..< 300).contains(response.statusCode) else {
                        let detail = await Self.collectText(response.lines)
                        throw ProviderError.http(status: response.statusCode, detail: detail)
                    }
                    var finishReason: String?
                    for try await line in response.lines {
                        if SSE.isDone(line) {
                            break
                        }
                        guard let chunk = SSE.chunk(from: line) else { continue }
                        if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                            continuation.yield(.delta(delta))
                        }
                        finishReason = chunk.choices.first?.finishReason ?? finishReason
                        if let usage = chunk.usage {
                            continuation.yield(
                                .usage(
                                    ProviderUsage(
                                        inputTokens: usage.promptTokens,
                                        outputTokens: usage.completionTokens,
                                        totalTokens: usage.totalTokens
                                    )
                                )
                            )
                        }
                    }
                    continuation.yield(.completed(finishReason: finishReason))
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorTimedOut {
                        continuation.finish(throwing: ProviderError.timeout)
                    } else if nsError.domain == NSURLErrorDomain {
                        continuation.finish(
                            throwing: ProviderError.transport(nsError.localizedDescription)
                        )
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func makeRequest(
        configuration: ProviderConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        maxTokens: Int
    ) throws -> URLRequest {
        guard let url = ProviderURL.endpoint(baseURL: configuration.baseURL, path: "chat/completions")
        else {
            throw ProviderError.invalidResponse("BaseURL 无法解析。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = ChatRequestBody(
            model: configuration.model,
            messages: messages,
            stream: true,
            temperature: 0.7,
            maxTokens: maxTokens,
            streamOptions: ChatStreamOptions(includeUsage: true)
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func collectText(_ lines: AsyncThrowingStream<String, Error>) async -> String {
        var collected: [String] = []
        var total = 0
        do {
            for try await line in lines {
                collected.append(line)
                total += line.count
                if total > 2000 {
                    break
                }
            }
        } catch {
            return collected.joined(separator: "\n")
        }
        return collected.joined(separator: "\n")
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }
}

/// Tiny SSE reader: OpenAI-compatible providers send one JSON object per
/// `data:` line and finish with `data: [DONE]`.
enum SSE {
    static func isDone(_ line: String) -> Bool {
        payload(line)?.trimmingCharacters(in: .whitespaces) == "[DONE]"
    }

    static func delta(from line: String) -> String? {
        chunk(from: line)?.choices.first?.delta?.content.flatMap { $0.isEmpty ? nil : $0 }
    }

    fileprivate static func chunk(from line: String) -> SSEChunk? {
        guard let payload = payload(line), payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SSEChunk.self, from: data)
    }

    static func payload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }

}

private struct ChatRequestBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double
    let maxTokens: Int
    let streamOptions: ChatStreamOptions

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
    }
}

private struct ChatStreamOptions: Encodable {
    let includeUsage: Bool

    private enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

fileprivate struct SSEChunk: Decodable {
    let choices: [SSEChoice]
    let usage: SSEUsage?
}

fileprivate struct SSEChoice: Decodable {
    let delta: SSEDelta?
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

fileprivate struct SSEDelta: Decodable {
    let content: String?
}

fileprivate struct SSEUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}
