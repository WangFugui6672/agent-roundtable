import Foundation

/// Result of a Provider connectivity check, rendered directly in the settings UI.
public enum ProviderCheckOutcome: Equatable, Sendable {
    /// `GET {baseURL}/models` answered 2xx. `modelCount` is nil when the
    /// provider does not return an OpenAI-style `data` array.
    case ok(modelCount: Int?)
    /// 401/403: the key is wrong, revoked, or lacks access to the endpoint.
    case invalidKey
    /// Transport-level failure (no network, DNS, TLS, timeout).
    case unreachable(String)
    /// Any other non-2xx answer: keep the status code visible.
    case failed(String)

    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case let .ok(modelCount):
            guard let modelCount else { return "连接成功。" }
            return "连接成功，可用模型 \(modelCount) 个。"
        case .invalidKey:
            return "API Key 无效或没有访问权限（HTTP 401/403）。"
        case let .unreachable(reason):
            return "网络请求失败：\(reason)"
        case let .failed(reason):
            return reason
        }
    }
}

/// Minimal, provider-agnostic check that the base URL and key actually work.
///
/// It calls the OpenAI-compatible `GET /models` endpoint. This is deliberately
/// not a chat completion: Issue #3 only needs to tell the user whether the
/// configuration is usable, and a model listing costs no tokens.
public struct ProviderProbe: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func check(configuration: ProviderConfiguration, apiKey: String) async -> ProviderCheckOutcome {
        guard let url = Self.modelsURL(baseURL: configuration.baseURL) else {
            return .failed("BaseURL 无法解析。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200 ..< 300:
                return .ok(modelCount: Self.modelCount(from: response.data))
            case 401, 403:
                return .invalidKey
            case 404:
                return .failed("BaseURL 路径可能不正确（HTTP 404）。请确认地址以 /v1 结尾。")
            default:
                return .failed("Provider 返回 HTTP \(response.statusCode)。")
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return .unreachable(nsError.localizedDescription)
            }
            return .failed(error.localizedDescription)
        }
    }

    static func modelsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/models")
    }

    private static func modelCount(from data: Data) -> Int? {
        struct ModelList: Decodable {
            struct Entry: Decodable {}
            let data: [Entry]?
        }
        return (try? JSONDecoder().decode(ModelList.self, from: data))?.data?.count
    }
}
