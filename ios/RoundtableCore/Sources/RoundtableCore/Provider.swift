import Foundation

// Provider configuration and credentials split, per ADR 0001:
// - `ProviderConfiguration` is non-secret and may be persisted locally.
// - The API key is only ever handed to `SecretStore` (Keychain) or an HTTP
//   request to the provider itself; it is never encoded into the configuration.

/// Supported provider presets (Issue #3). All are OpenAI-compatible.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case qwen
    case deepseek
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen: return "通义千问"
        case .deepseek: return "DeepSeek"
        case .custom: return "自定义"
        }
    }

    /// Default OpenAI-compatible endpoint. Empty for `.custom`: the user must fill it in.
    public var defaultBaseURL: String {
        switch self {
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .qwen: return "qwen-plus"
        case .deepseek: return "deepseek-chat"
        case .custom: return ""
        }
    }

    public var isCustom: Bool { self == .custom }
}

/// Non-secret provider configuration (GLOSSARY: Provider 配置).
public struct ProviderConfiguration: Codable, Equatable, Sendable, Identifiable {
    public let kind: ProviderKind
    public var baseURL: String
    public var model: String

    public var id: String { kind.rawValue }

    public init(kind: ProviderKind, baseURL: String, model: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    /// Non-secret wire snapshot submitted with `POST /api/v1/roundtables`.
    public var metadata: ProviderMetadata {
        ProviderMetadata(kind: kind, baseURL: baseURL, model: model)
    }
}

/// Provider metadata as it travels over the wire (docs/protocol.md 2.5).
public struct ProviderMetadata: Codable, Equatable, Sendable {
    public let kind: ProviderKind
    public let baseURL: String
    public let model: String

    public init(kind: ProviderKind, baseURL: String, model: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    // Explicit `baseUrl` key: the local JSON storage stays readable while the
    // `.roundtable` encoder still produces `base_url` for the wire.
    private enum CodingKeys: String, CodingKey {
        case kind
        case baseURL = "baseUrl"
        case model
    }
}

/// Whether a roundtable can use the selected provider, and why not when it can't.
///
/// `.incomplete` exists so a missing Keychain item never silently degrades a
/// real roundtable into the Mock demo (PRD 7.13: 缺失时要求用户重新输入).
public enum ProviderAvailability: Equatable, Sendable {
    case none
    case ready(ProviderMetadata)
    case incomplete(String)
}

/// What the user typed in the provider form, before validation.
public struct ProviderDraft: Equatable, Sendable {
    public var kind: ProviderKind
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(kind: ProviderKind, baseURL: String, model: String, apiKey: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public init(kind: ProviderKind) {
        self.init(
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModel,
            apiKey: ""
        )
    }

    /// Validates and trims the draft. The returned key is the exact string to
    /// hand to the Keychain; it never becomes part of the configuration.
    public func validated() throws -> (configuration: ProviderConfiguration, apiKey: String) {
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty else { throw ProviderValidationError.missingBaseURL }
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw ProviderValidationError.invalidBaseURL
        }
        guard !model.isEmpty else { throw ProviderValidationError.missingModel }
        guard !apiKey.isEmpty else { throw ProviderValidationError.missingAPIKey }
        guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ProviderValidationError.apiKeyContainsWhitespace
        }

        // The backend normalizes trailing slashes too (docs/protocol.md 2.5), so
        // the local configuration and the stored snapshot stay identical.
        return (
            ProviderConfiguration(
                kind: kind,
                baseURL: ProviderURL.normalized(baseURL: baseURL),
                model: model
            ),
            apiKey
        )
    }
}

/// One place that turns a BaseURL into a request URL.
public enum ProviderURL {
    public static func normalized(baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public static func endpoint(baseURL: String, path: String) -> URL? {
        let normalized = normalized(baseURL: baseURL)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized + "/" + path)
    }

    public static func modelsEndpoint(baseURL: String) -> URL? {
        endpoint(baseURL: baseURL, path: "models")
    }
}

public enum ProviderValidationError: Error, Equatable, Sendable {
    case missingBaseURL
    case invalidBaseURL
    case missingModel
    case missingAPIKey
    case apiKeyContainsWhitespace

    public var message: String {
        switch self {
        case .missingBaseURL: return "请填写 BaseURL。"
        case .invalidBaseURL: return "BaseURL 必须是完整的 http 或 https 地址。"
        case .missingModel: return "请填写 Model。"
        case .missingAPIKey: return "请填写 API Key。"
        case .apiKeyContainsWhitespace: return "API Key 不应包含空格或换行。"
        }
    }
}
