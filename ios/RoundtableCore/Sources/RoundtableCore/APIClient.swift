import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: "invalid_response", message: "不是 HTTP 响应。", statusCode: 0)
        }
        return HTTPResponse(data: data, statusCode: http.statusCode)
    }
}

public struct APIError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let statusCode: Int

    public init(code: String, message: String, statusCode: Int) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
    }
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }

    let error: Body
}

public struct APIClient: Sendable {
    public let baseURL: URL
    public let guestSessionId: UUID?

    private let transport: HTTPTransport

    public init(
        baseURL: URL,
        transport: HTTPTransport = URLSessionTransport(),
        guestSessionId: UUID? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.guestSessionId = guestSessionId
    }

    public func withGuestSession(_ id: UUID?) -> APIClient {
        APIClient(baseURL: baseURL, transport: transport, guestSessionId: id)
    }

    public func createGuestSession() async throws -> GuestSession {
        try await send(makeRequest(path: "api/v1/guest-sessions", method: "POST"))
    }

    public func fetchAgentProfiles() async throws -> [AgentProfile] {
        try await send(makeRequest(path: "api/v1/agent-profiles", method: "GET"))
    }

    public func createRoundtable(
        topic: String,
        agentProfileIds: [UUID],
        provider: ProviderMetadata? = nil
    ) async throws -> RoundtableSnapshot {
        struct Body: Encodable {
            let topic: String
            let agentProfileIds: [UUID]
            let provider: ProviderMetadata?
        }
        let body = try JSONEncoder.roundtable.encode(
            Body(topic: topic, agentProfileIds: agentProfileIds, provider: provider)
        )
        return try await send(
            makeRequest(path: "api/v1/roundtables", method: "POST", body: body)
        )
    }

    /// Persists one structured utterance and returns the ``message.completed``
    /// envelope, which the client applies locally and the server broadcasts.
    public func submitMessage(
        roundtableID: UUID,
        submission: MessageSubmission
    ) async throws -> EventEnvelope {
        let body = try JSONEncoder.roundtable.encode(submission)
        return try await send(
            makeRequest(
                path: "api/v1/roundtables/\(roundtableID.uuidString)/messages",
                method: "POST",
                body: body
            )
        )
    }

    public func fetchRoundtable(id: UUID) async throws -> RoundtableSnapshot {
        try await send(makeRequest(path: "api/v1/roundtables/\(id.uuidString)", method: "GET"))
    }

    // MARK: - Plumbing

    private func makeRequest(path: String, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let guestSessionId {
            request.setValue(guestSessionId.uuidString, forHTTPHeaderField: "X-Guest-Session")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw error(from: response)
        }
        do {
            return try JSONDecoder.roundtable.decode(T.self, from: response.data)
        } catch {
            throw APIError(
                code: "invalid_response",
                message: "服务端响应格式不正确。",
                statusCode: response.statusCode
            )
        }
    }

    private func error(from response: HTTPResponse) -> APIError {
        if let envelope = try? JSONDecoder.roundtable.decode(ErrorEnvelope.self, from: response.data) {
            return APIError(
                code: envelope.error.code,
                message: envelope.error.message,
                statusCode: response.statusCode
            )
        }
        return APIError(
            code: "http_\(response.statusCode)",
            message: "请求失败（HTTP \(response.statusCode)）。",
            statusCode: response.statusCode
        )
    }
}
