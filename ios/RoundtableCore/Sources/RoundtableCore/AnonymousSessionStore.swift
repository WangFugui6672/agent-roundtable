import Foundation

/// Stores the anonymous bearer token in Keychain rather than UserDefaults.
public struct AnonymousSessionStore {
    public static let keychainService = "com.wangfugui.agentroundtable.guest-session"
    public static let account = "guest-session"

    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainStore(service: keychainService)) {
        self.secrets = secrets
    }

    public func load() throws -> UUID? {
        guard let raw = try secrets.secret(for: Self.account) else { return nil }
        return UUID(uuidString: raw)
    }

    public func save(_ id: UUID) throws {
        try secrets.setSecret(id.uuidString, for: Self.account)
    }

    public func clear() throws {
        try secrets.removeSecret(for: Self.account)
    }
}
