import Foundation
import Security

/// Storage abstraction for provider secrets.
///
/// Production uses ``KeychainStore``; tests use an in-memory double. Keeping the
/// seam explicit means provider logic is testable on any platform, including CI
/// machines where the login keychain behaves differently from a simulator.
public protocol SecretStore {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func removeSecret(for account: String) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var message: String {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return "Keychain 操作失败（\(status)）：\(description)"
    }
}

/// API-key storage backed by the iOS Keychain (ADR 0001).
///
/// Items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: the key is not
/// included in device backups and does not migrate to a new device.
public struct KeychainStore: SecretStore {
    /// Single source of truth for the service name; `ProviderStore` reuses it.
    public static let defaultService = "com.wangfugui.agentroundtable.provider"

    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return secret
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
