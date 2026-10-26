import Security
import XCTest

import RoundtableCore

/// Keychain integration tests. They need a host app (simulator), which is why
/// they live in the app test bundle instead of the platform-neutral package.
final class KeychainStoreTests: XCTestCase {
    private let service = "com.wangfugui.agentroundtable.tests"
    private var account = ""

    private var store: KeychainStore {
        KeychainStore(service: service)
    }

    override func setUp() {
        super.setUp()
        account = "test.\(UUID().uuidString)"
        let cleanupAccount = account
        addTeardownBlock {
            try? KeychainStore(service: "com.wangfugui.agentroundtable.tests")
                .removeSecret(for: cleanupAccount)
        }
    }

    func testMissingSecretReturnsNil() throws {
        XCTAssertNil(try store.secret(for: account))
    }

    func testSaveAndReadRoundTrip() throws {
        try store.setSecret("sk-test-123", for: account)

        XCTAssertEqual(try store.secret(for: account), "sk-test-123")
    }

    func testSaveOverwritesExistingSecret() throws {
        try store.setSecret("sk-first", for: account)
        try store.setSecret("sk-second", for: account)

        XCTAssertEqual(try store.secret(for: account), "sk-second")
        XCTAssertEqual(try itemCount(), 1, "misuse of the keychain would leave duplicate items")
    }

    func testDeleteRemovesSecret() throws {
        try store.setSecret("sk-test-123", for: account)

        try store.removeSecret(for: account)

        XCTAssertNil(try store.secret(for: account))
        XCTAssertEqual(try itemCount(), 0)
    }

    func testDeleteMissingSecretIsIdempotent() {
        XCTAssertNoThrow(try store.removeSecret(for: account))
        XCTAssertNoThrow(try store.removeSecret(for: account))
    }

    func testItemIsAccessibleOnlyWhenUnlockedAndOnThisDevice() throws {
        try store.setSecret("sk-test-123", for: account)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(
            status,
            errSecSuccess,
            "expected WhenUnlockedThisDeviceOnly, got status \(status)"
        )

        // Sanity check: the same query fails when a different accessibility class is required.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var other: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &other), errSecItemNotFound)
    }

    func testProviderStoreUsesKeychainAndKeepsKeyOutOfDefaults() throws {
        let suiteName = "roundtable.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = KeychainStore(service: service)
        let kind = ProviderKind.custom
        addTeardownBlock { try? keychain.removeSecret(for: ProviderStore.account(for: kind)) }

        let first = ProviderStore(
            secrets: keychain,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        try first.save(
            ProviderDraft(
                kind: kind,
                baseURL: "https://example.com/v1",
                model: "custom-model",
                apiKey: "sk-secret-do-not-persist"
            )
        )

        // A new ProviderStore simulates an app restart: configuration and key
        // must both come back from their respective stores.
        let restarted = ProviderStore(
            secrets: KeychainStore(service: service),
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        XCTAssertTrue(restarted.isConfigured(kind))
        XCTAssertEqual(try restarted.secret(for: kind), "sk-secret-do-not-persist")
        XCTAssertEqual(restarted.configuration(for: kind)?.model, "custom-model")

        let dumpedDefaults = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(
            dumpedDefaults.contains("sk-secret-do-not-persist"),
            "API key must never be written to UserDefaults"
        )

        try restarted.delete(kind)
        XCTAssertNil(try KeychainStore(service: service).secret(for: ProviderStore.account(for: kind)))
        XCTAssertFalse(restarted.isConfigured(kind))
    }

    private func itemCount() throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return 0
        }
        XCTAssertEqual(status, errSecSuccess)
        return (items as? [[String: Any]])?.count ?? 0
    }
}
