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

#if targetEnvironment(macCatalyst)
    private static let ephemeralLock = NSLock()
    private static var ephemeralSecrets: [String: String] = [:]
    private static var ephemeralStorageUsed = false
#endif

    public let service: String

    /// True only when an unsigned Mac Catalyst build cannot access either
    /// Keychain implementation and falls back to process-local storage.
    public static var isUsingEphemeralStorage: Bool {
#if targetEnvironment(macCatalyst)
        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        return ephemeralStorageUsed
#else
        return false
#endif
    }

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var lookup = makeQuery(account: account, useDataProtection: true)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecMissingEntitlement {
            lookup = makeQuery(account: account, useDataProtection: false)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(lookup as CFDictionary, &item)
            if status == errSecMissingEntitlement {
#if targetEnvironment(macCatalyst)
                // Ad-hoc Catalyst builds have no application identifier
                // entitlement. Keep demo secrets process-local, never on disk.
                markEphemeralStorageUsed()
                return ephemeralSecret(for: account)
#endif
            }
        }
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
        let lookup = makeQuery(account: account, useDataProtection: true)

        var updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecMissingEntitlement {
            updateStatus = SecItemUpdate(
                makeQuery(account: account, useDataProtection: false) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecMissingEntitlement {
#if targetEnvironment(macCatalyst)
                setEphemeralSecret(secret, for: account)
                return
#endif
            }
        }
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var attributes = lookup
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            attributes = makeQuery(account: account, useDataProtection: false)
            attributes[kSecValueData as String] = data
            addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecMissingEntitlement {
#if targetEnvironment(macCatalyst)
                setEphemeralSecret(secret, for: account)
                return
#endif
            }
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    public func removeSecret(for account: String) throws {
        var status = SecItemDelete(
            makeQuery(account: account, useDataProtection: true) as CFDictionary
        )
        if status == errSecMissingEntitlement {
            status = SecItemDelete(
                makeQuery(account: account, useDataProtection: false) as CFDictionary
            )
            if status == errSecMissingEntitlement {
#if targetEnvironment(macCatalyst)
                removeEphemeralSecret(for: account)
                return
#endif
            }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func makeQuery(account: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
#if targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = useDataProtection
#else
        _ = useDataProtection
#endif
        return query
    }

#if targetEnvironment(macCatalyst)
    private var ephemeralKeyPrefix: String {
        "\(service)|"
    }

    private func ephemeralSecret(for account: String) -> String? {
        Self.ephemeralLock.lock()
        defer { Self.ephemeralLock.unlock() }
        return Self.ephemeralSecrets[ephemeralKeyPrefix + account]
    }

    private func setEphemeralSecret(_ secret: String, for account: String) {
        Self.ephemeralLock.lock()
        Self.ephemeralStorageUsed = true
        Self.ephemeralSecrets[ephemeralKeyPrefix + account] = secret
        Self.ephemeralLock.unlock()
    }

    private func removeEphemeralSecret(for account: String) {
        Self.ephemeralLock.lock()
        Self.ephemeralStorageUsed = true
        Self.ephemeralSecrets.removeValue(forKey: ephemeralKeyPrefix + account)
        Self.ephemeralLock.unlock()
    }

    private func markEphemeralStorageUsed() {
        Self.ephemeralLock.lock()
        Self.ephemeralStorageUsed = true
        Self.ephemeralLock.unlock()
    }
#endif
}
