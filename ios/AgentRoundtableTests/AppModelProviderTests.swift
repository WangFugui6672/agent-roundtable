import XCTest

import RoundtableCore

@testable import AgentRoundtable

private final class FakeSecretStore: SecretStore {
    var values: [String: String] = [:]

    func secret(for account: String) throws -> String? {
        values[account]
    }

    func setSecret(_ secret: String, for account: String) throws {
        values[account] = secret
    }

    func removeSecret(for account: String) throws {
        values[account] = nil
    }
}

@MainActor
final class AppModelProviderTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: FakeSecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.appmodel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = FakeSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeModel() -> AppModel {
        let store = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        return AppModel(defaults: defaults, providerStore: store)
    }

    func testProviderMetadataIsNilWithoutConfiguration() {
        let model = makeModel()

        XCTAssertNil(model.providerMetadata())
        XCTAssertFalse(model.hasConfiguredProvider)
        XCTAssertTrue(model.providerSummary.contains("Mock"))
    }

    func testSavingProviderExposesMetadata() throws {
        let model = makeModel()

        let saved = model.saveProvider(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-test"
        )

        XCTAssertTrue(saved)
        XCTAssertNil(model.providerError)
        XCTAssertEqual(model.providerMetadata()?.kind, .deepseek)
        XCTAssertEqual(model.providerMetadata()?.model, "deepseek-chat")
        XCTAssertTrue(model.providerSummary.contains("DeepSeek"))
    }

    func testActiveProviderSurvivesRestart() {
        let model = makeModel()
        model.saveProvider(
            kind: .qwen,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus",
            apiKey: "sk-qwen"
        )

        let restarted = makeModel()

        XCTAssertEqual(restarted.activeProvider, .qwen)
        XCTAssertEqual(restarted.providerMetadata()?.kind, .qwen)
    }

    func testSavingWithEmptyKeyKeepsStoredKey() throws {
        let model = makeModel()
        model.saveProvider(
            kind: .custom,
            baseURL: "https://example.com/v1",
            model: "m1",
            apiKey: "sk-kept"
        )

        model.saveProvider(
            kind: .custom,
            baseURL: "https://example.com/v2",
            model: "m2",
            apiKey: "   "
        )

        XCTAssertEqual(secrets.values[ProviderStore.account(for: .custom)], "sk-kept")
        XCTAssertEqual(model.providerMetadata()?.baseURL, "https://example.com/v2")
        XCTAssertEqual(model.providerMetadata()?.model, "m2")
    }

    func testValidationErrorIsSurfaced() {
        let model = makeModel()

        let saved = model.saveProvider(
            kind: .custom,
            baseURL: "not-a-url",
            model: "m",
            apiKey: "sk"
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(model.providerError?.contains("BaseURL") == true)
        XCTAssertNil(model.providerMetadata())
    }

    func testDeletingActiveProviderClearsMetadataAndSecret() {
        let model = makeModel()
        model.saveProvider(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-test"
        )

        model.deleteProvider(.deepseek)

        XCTAssertNil(model.providerMetadata())
        XCTAssertNil(model.activeProvider)
        XCTAssertNil(secrets.values[ProviderStore.account(for: .deepseek)])
    }
}
