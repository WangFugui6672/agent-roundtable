import XCTest

@testable import RoundtableCore

/// In-memory SecretStore so provider logic can be tested without Keychain.
final class MemorySecretStore: SecretStore {
    private(set) var values: [String: String] = [:]
    private(set) var removedAccounts: [String] = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func secret(for account: String) throws -> String? {
        values[account]
    }

    func setSecret(_ secret: String, for account: String) throws {
        values[account] = secret
    }

    func removeSecret(for account: String) throws {
        removedAccounts.append(account)
        values[account] = nil
    }
}

final class MemoryProviderStorage: ProviderConfigurationStorage {
    private(set) var configurations: [ProviderConfiguration]

    init(configurations: [ProviderConfiguration] = []) {
        self.configurations = configurations
    }

    func load() -> [ProviderConfiguration] {
        configurations
    }

    func save(_ configurations: [ProviderConfiguration]) {
        self.configurations = configurations
    }
}

private final class ThrowingSecretStore: SecretStore {
    func secret(for account: String) throws -> String? {
        throw KeychainError(status: -25308) // errSecInteractionNotAllowed
    }

    func setSecret(_ secret: String, for account: String) throws {
        throw KeychainError(status: -25308)
    }

    func removeSecret(for account: String) throws {
        throw KeychainError(status: -25308)
    }
}

final class ProviderTests: XCTestCase {
    private func makeStore(
        secrets: MemorySecretStore = MemorySecretStore(),
        storage: MemoryProviderStorage = MemoryProviderStorage()
    ) -> (ProviderStore, MemorySecretStore, MemoryProviderStorage) {
        (ProviderStore(secrets: secrets, storage: storage), secrets, storage)
    }

    func testPresetsExposeDefaultEndpoints() {
        XCTAssertEqual(ProviderKind.qwen.defaultBaseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(ProviderKind.qwen.defaultModel, "qwen-plus")
        XCTAssertEqual(ProviderKind.deepseek.defaultBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(ProviderKind.deepseek.defaultModel, "deepseek-chat")
        XCTAssertEqual(ProviderKind.custom.defaultBaseURL, "")
        XCTAssertEqual(ProviderKind.custom.defaultModel, "")
        XCTAssertEqual(ProviderKind.allCases.map(\.displayName), ["通义千问", "DeepSeek", "自定义"])
    }

    func testDraftValidationTrimsValues() throws {
        let draft = ProviderDraft(
            kind: .deepseek,
            baseURL: "  https://api.deepseek.com/v1/  ",
            model: " deepseek-chat ",
            apiKey: "  sk-test-123  "
        )

        let (configuration, key) = try draft.validated()

        XCTAssertEqual(configuration, ProviderConfiguration(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        ))
        XCTAssertEqual(key, "sk-test-123")
    }

    func testDraftRejectsMissingFields() {
        func assertError(_ draft: ProviderDraft, _ expected: ProviderValidationError, line: UInt = #line) {
            XCTAssertThrowsError(try draft.validated(), line: line) { error in
                XCTAssertEqual(error as? ProviderValidationError, expected, line: line)
            }
        }

        assertError(
            ProviderDraft(kind: .custom, baseURL: "  ", model: "m", apiKey: "k"),
            .missingBaseURL
        )
        assertError(
            ProviderDraft(kind: .custom, baseURL: "https://example.com/v1", model: " ", apiKey: "k"),
            .missingModel
        )
        assertError(
            ProviderDraft(kind: .custom, baseURL: "https://example.com/v1", model: "m", apiKey: " "),
            .missingAPIKey
        )
    }

    func testDraftRejectsInvalidBaseURL() {
        for baseURL in ["api.deepseek.com", "ftp://example.com/v1", "https://"] {
            XCTAssertThrowsError(
                try ProviderDraft(kind: .custom, baseURL: baseURL, model: "m", apiKey: "k").validated(),
                "expected \(baseURL) to be rejected"
            ) { error in
                XCTAssertEqual(error as? ProviderValidationError, .invalidBaseURL)
            }
        }
    }

    func testDraftRejectsAPIKeyWithWhitespace() {
        let draft = ProviderDraft(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-test\n123"
        )

        XCTAssertThrowsError(try draft.validated()) { error in
            XCTAssertEqual(error as? ProviderValidationError, .apiKeyContainsWhitespace)
        }
    }

    func testValidationErrorsHaveReadableMessages() {
        XCTAssertFalse(ProviderValidationError.missingBaseURL.message.isEmpty)
        XCTAssertTrue(ProviderValidationError.invalidBaseURL.message.contains("http"))
        XCTAssertTrue(ProviderValidationError.missingAPIKey.message.contains("API Key"))
    }

    func testSaveKeepsSecretOutOfConfigurationStorage() throws {
        let (store, secrets, storage) = makeStore()

        try store.save(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-super-secret"
            )
        )

        XCTAssertEqual(secrets.values[ProviderStore.account(for: .deepseek)], "sk-super-secret")
        XCTAssertEqual(storage.configurations.count, 1)
        XCTAssertEqual(storage.configurations[0].model, "deepseek-chat")

        let persisted = try JSONEncoder().encode(storage.configurations)
        let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(text.contains("sk-super-secret"), "configuration storage must never hold the key")
        XCTAssertFalse(text.lowercased().contains("apikey"))
    }

    func testConfigurationSurvivesRestart() throws {
        let secrets = MemorySecretStore()
        let storage = MemoryProviderStorage()
        let first = ProviderStore(secrets: secrets, storage: storage)
        try first.save(
            ProviderDraft(
                kind: .qwen,
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                model: "qwen-plus",
                apiKey: "sk-qwen"
            )
        )

        let restarted = ProviderStore(secrets: secrets, storage: storage)

        XCTAssertTrue(restarted.isConfigured(.qwen))
        XCTAssertEqual(restarted.configuration(for: .qwen)?.model, "qwen-plus")
        XCTAssertEqual(try restarted.secret(for: .qwen), "sk-qwen")
    }

    func testConfiguredRequiresASecret() {
        let storage = MemoryProviderStorage(configurations: [
            ProviderConfiguration(kind: .custom, baseURL: "https://example.com/v1", model: "m")
        ])
        let (store, _, _) = makeStore(storage: storage)

        XCTAssertFalse(store.isConfigured(.custom))
        XCTAssertNil(store.configuration(for: .deepseek))
    }

    func testSaveUpdatesExistingConfiguration() throws {
        let (store, secrets, storage) = makeStore()

        try store.save(ProviderDraft(kind: .deepseek, baseURL: "https://a/v1", model: "m1", apiKey: "k1"))
        try store.save(ProviderDraft(kind: .deepseek, baseURL: "https://b/v1", model: "m2", apiKey: "k2"))

        XCTAssertEqual(storage.configurations.count, 1)
        XCTAssertEqual(store.configuration(for: .deepseek)?.baseURL, "https://b/v1")
        XCTAssertEqual(secrets.values.count, 1)
        XCTAssertEqual(try store.secret(for: .deepseek), "k2")
    }

    func testDeleteRemovesConfigurationAndSecret() throws {
        let (store, secrets, storage) = makeStore()
        try store.save(ProviderDraft(kind: .deepseek, baseURL: "https://a/v1", model: "m", apiKey: "k"))

        try store.delete(.deepseek)

        XCTAssertNil(store.configuration(for: .deepseek))
        XCTAssertFalse(store.isConfigured(.deepseek))
        XCTAssertEqual(secrets.removedAccounts, [ProviderStore.account(for: .deepseek)])
        XCTAssertTrue(storage.configurations.isEmpty)
    }

    func testDeleteOfUnknownProviderIsIdempotent() throws {
        let (store, _, _) = makeStore()

        XCTAssertNoThrow(try store.delete(.custom))
        XCTAssertNil(store.configuration(for: .custom))
    }

    func testAvailabilityIsNoneWithoutConfiguration() {
        let (store, _, _) = makeStore()

        XCTAssertEqual(store.availability(for: .deepseek), .none)
        XCTAssertEqual(store.availability(for: nil), .none)
    }

    func testAvailabilityIsReadyWithStoredKey() throws {
        let (store, _, _) = makeStore()
        try store.save(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-test"
            )
        )

        XCTAssertEqual(
            store.availability(for: .deepseek),
            .ready(
                ProviderMetadata(
                    kind: .deepseek,
                    baseURL: "https://api.deepseek.com/v1",
                    model: "deepseek-chat"
                )
            )
        )
    }

    func testAvailabilityIsIncompleteWhenKeyDisappears() {
        let storage = MemoryProviderStorage(configurations: [
            ProviderConfiguration(kind: .custom, baseURL: "https://example.com/v1", model: "m")
        ])
        let (store, _, _) = makeStore(storage: storage)

        guard case let .incomplete(message) = store.availability(for: .custom) else {
            return XCTFail("expected .incomplete")
        }
        XCTAssertTrue(message.contains("API Key"))
    }

    func testAvailabilitySurfacesKeychainErrorsInsteadOfMocking() {
        let storage = MemoryProviderStorage(configurations: [
            ProviderConfiguration(kind: .deepseek, baseURL: "https://api.deepseek.com/v1", model: "m")
        ])
        let store = ProviderStore(secrets: ThrowingSecretStore(), storage: storage)

        guard case let .incomplete(message) = store.availability(for: .deepseek) else {
            return XCTFail("expected .incomplete")
        }
        XCTAssertTrue(message.contains("Keychain"))
    }

    func testProviderMetadataMatchesWireShape() throws {
        let configuration = ProviderConfiguration(
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus"
        )

        let data = try JSONEncoder.roundtable.encode(configuration.metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["kind"] as? String, "qwen")
        XCTAssertEqual(json["base_url"] as? String, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(json["model"] as? String, "qwen-plus")
        XCTAssertNil(json["api_key"])
        XCTAssertNil(json["apiKey"])
    }

    func testRoundtableSnapshotDecodesProviderMetadata() throws {
        let snapshot = try JSONDecoder.roundtable.decode(
            RoundtableSnapshot.self,
            from: Data(Fixtures.providerSnapshotJSON.utf8)
        )

        XCTAssertEqual(snapshot.provider?.kind, .deepseek)
        XCTAssertEqual(snapshot.provider?.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(snapshot.provider?.model, "deepseek-chat")
    }

    func testRoundtableSnapshotWithoutProviderDecodesAsNil() throws {
        let snapshot = try JSONDecoder.roundtable.decode(
            RoundtableSnapshot.self,
            from: Data(Fixtures.snapshotJSON.utf8)
        )

        XCTAssertNil(snapshot.provider)
    }
}
