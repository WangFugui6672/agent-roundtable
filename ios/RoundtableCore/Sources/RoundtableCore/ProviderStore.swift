import Foundation

/// Persistence decided by the app, not by ``ProviderStore``: tests inject an
/// in-memory implementation, production writes JSON into `UserDefaults`.
public protocol ProviderConfigurationStorage {
    func load() -> [ProviderConfiguration]
    func save(_ configurations: [ProviderConfiguration])
}

/// Default non-secret storage. Only `kind`, `baseURL` and `model` are written;
/// the API key lives in the Keychain (ADR 0001).
public struct UserDefaultsProviderStorage: ProviderConfigurationStorage {
    public static let storageKey = "roundtable.providerConfigurations"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [ProviderConfiguration] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([ProviderConfiguration].self, from: data)) ?? []
    }

    public func save(_ configurations: [ProviderConfiguration]) {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Owns the provider lifecycle: non-secret configuration plus the Keychain item
/// that matches it. One configuration per provider preset in the MVP.
public final class ProviderStore {
    public static let keychainService = KeychainStore.defaultService

    private let secrets: SecretStore
    private let storage: ProviderConfigurationStorage
    private var configurationsByKind: [ProviderKind: ProviderConfiguration]

    public init(
        secrets: SecretStore = KeychainStore(),
        storage: ProviderConfigurationStorage = UserDefaultsProviderStorage()
    ) {
        self.secrets = secrets
        self.storage = storage
        self.configurationsByKind = storage.load().reduce(into: [:]) { result, configuration in
            result[configuration.kind] = configuration
        }
    }

    public static func account(for kind: ProviderKind) -> String {
        "provider.\(kind.rawValue)"
    }

    public var configurations: [ProviderConfiguration] {
        ProviderKind.allCases.compactMap { configurationsByKind[$0] }
    }

    public func configuration(for kind: ProviderKind) -> ProviderConfiguration? {
        configurationsByKind[kind]
    }

    public func secret(for kind: ProviderKind) throws -> String? {
        try secrets.secret(for: Self.account(for: kind))
    }

    /// A provider is usable only when both halves exist: configuration and key.
    public func isConfigured(_ kind: ProviderKind) -> Bool {
        guard configurationsByKind[kind] != nil else { return false }
        guard let secret = try? secrets.secret(for: Self.account(for: kind)) else { return false }
        return !secret.isEmpty
    }

    /// Resolves the selected provider without swallowing Keychain failures:
    /// an unreadable or missing key becomes `.incomplete`, never a silent Mock
    /// roundtable (PRD 7.13).
    public func availability(for kind: ProviderKind?) -> ProviderAvailability {
        guard let kind, let configuration = configurationsByKind[kind] else {
            return .none
        }
        do {
            guard let secret = try secrets.secret(for: Self.account(for: kind)) else {
                return .incomplete("API Key 已不存在，请重新输入。")
            }
            guard !secret.isEmpty else {
                return .incomplete("API Key 为空，请重新输入。")
            }
            return .ready(configuration.metadata)
        } catch let error as KeychainError {
            return .incomplete("无法读取 Keychain：\(error.message)")
        } catch {
            return .incomplete("无法读取 Keychain：\(error.localizedDescription)")
        }
    }

    @discardableResult
    public func save(_ draft: ProviderDraft) throws -> ProviderConfiguration {
        let (configuration, apiKey) = try draft.validated()

        // Write the secret first: if the Keychain rejects it, no half-saved
        // configuration is left behind.
        try secrets.setSecret(apiKey, for: Self.account(for: configuration.kind))
        configurationsByKind[configuration.kind] = configuration
        storage.save(configurations)
        return configuration
    }

    public func delete(_ kind: ProviderKind) throws {
        try secrets.removeSecret(for: Self.account(for: kind))
        configurationsByKind[kind] = nil
        storage.save(configurations)
    }

    /// Removes every provider configuration and Keychain item. UI tests use it
    /// through `RT_RESET_PROVIDER_STATE=1` so each run starts from a known state.
    public func reset() {
        for kind in ProviderKind.allCases {
            try? secrets.removeSecret(for: Self.account(for: kind))
        }
        configurationsByKind.removeAll()
        storage.save([])
    }
}
