import Foundation

/// Result of a Provider connectivity check, rendered directly in the settings UI.
public enum ProviderCheckOutcome: Equatable, Sendable {
    /// `GET {baseURL}/models` answered 2xx. `modelCount` is nil when the
    /// provider does not return an OpenAI-style `data` array.
    case ok(modelCount: Int?)
    /// 401/403: the key is wrong, revoked, or lacks access to the endpoint.
    case invalidKey
    /// 2xx, but the configured model is not in the provider's model list.
    case modelMissing(String)
    /// Transport-level failure (no network, DNS, TLS, timeout).
    case unreachable(String)
    /// Any other non-2xx answer: keep the status code visible.
    case failed(String)

    public var message: String {
        switch self {
        case let .ok(modelCount):
            guard let modelCount else { return "连接成功。" }
            return "连接成功，可用模型 \(modelCount) 个。"
        case .invalidKey:
            return "API Key 无效或没有访问权限（HTTP 401/403）。"
        case let .modelMissing(model):
            return "连接成功，但模型 \(model) 不在该 Provider 的模型列表中。"
        case let .unreachable(reason):
            return "网络请求失败：\(reason)"
        case let .failed(reason):
            return reason
        }
    }
}

/// Minimal, provider-agnostic check that the base URL, key and model are usable.
///
/// It calls the OpenAI-compatible `GET /models` endpoint. This is deliberately
/// not a chat completion: Issue #3 only needs to tell the user whether the
/// configuration is usable, and a model listing costs no tokens.
public struct ProviderProbe: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func check(
        configuration: ProviderConfiguration,
        apiKey: String
    ) async -> ProviderCheckOutcome {
        guard let url = ProviderURL.modelsEndpoint(baseURL: configuration.baseURL) else {
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
                let models = Self.modelIDs(from: response.data)
                if let models, !models.isEmpty, !models.contains(configuration.model) {
                    return .modelMissing(configuration.model)
                }
                return .ok(modelCount: models?.count)
            case 401, 403:
                return .invalidKey
            case 402:
                return .failed("Provider 返回 HTTP 402：余额不足或计费方式未开通。")
            case 404:
                return .failed("BaseURL 路径可能不正确（HTTP 404）。请确认地址以 /v1 结尾。")
            case 429:
                return .failed("Provider 返回 HTTP 429：请求过于频繁，请稍后重试。")
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

    /// Model IDs from an OpenAI-style `{"data": [{"id": "..."}]}` body, or nil
    /// when the provider returns something else (some proxies answer `{}`).
    private static func modelIDs(from data: Data) -> [String]? {
        (try? JSONDecoder().decode(ModelList.self, from: data))?.data?.compactMap(\.id)
    }
}

private struct ModelList: Decodable {
    struct Entry: Decodable {
        let id: String?
    }

    let data: [Entry]?
}
