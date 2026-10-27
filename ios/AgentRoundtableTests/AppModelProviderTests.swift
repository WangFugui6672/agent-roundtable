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

private actor StubTransport: HTTPTransport {
    private let statusCode: Int

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(data: Data(), statusCode: statusCode)
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

    private func makeModel(probe: ProviderProbe = ProviderProbe()) -> AppModel {
        let store = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        return AppModel(defaults: defaults, providerStore: store, probe: probe)
    }

    private func deepseekDraft(apiKey: String = "sk-test") -> ProviderDraft {
        ProviderDraft(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: apiKey
        )
    }

    func testProviderMetadataIsNilWithoutConfiguration() {
        let model = makeModel()

        XCTAssertNil(model.providerMetadata)
        XCTAssertFalse(model.hasConfiguredProvider)
        XCTAssertTrue(model.providerSummary.contains("Mock"))
        XCTAssertNil(model.providerIncompleteMessage)
    }

    func testSavingProviderExposesMetadata() {
        let model = makeModel()

        let saved = model.saveProvider(deepseekDraft())

        XCTAssertTrue(saved)
        XCTAssertNil(model.providerError)
        XCTAssertEqual(model.providerMetadata?.kind, .deepseek)
        XCTAssertEqual(model.providerMetadata?.model, "deepseek-chat")
        XCTAssertTrue(model.providerSummary.contains("DeepSeek"))
    }

    func testActiveProviderSurvivesRestart() {
        let model = makeModel()
        model.saveProvider(
            ProviderDraft(
                kind: .qwen,
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                model: "qwen-plus",
                apiKey: "sk-qwen"
            )
        )

        let restarted = makeModel()

        XCTAssertEqual(restarted.activeProvider, .qwen)
        XCTAssertEqual(restarted.providerMetadata?.kind, .qwen)
    }

    func testSavingWithEmptyKeyKeepsStoredKey() {
        let model = makeModel()
        model.saveProvider(deepseekDraft())

        model.saveProvider(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "   "
            )
        )

        XCTAssertEqual(secrets.values[ProviderStore.account(for: .deepseek)], "sk-test")
        XCTAssertEqual(model.providerMetadata?.model, "deepseek-chat")
    }

    func testChangingBaseURLRequiresANewKey() {
        let model = makeModel()
        model.saveProvider(deepseekDraft())

        let saved = model.saveProvider(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://evil.example.com/v1",
                model: "deepseek-chat",
                apiKey: ""
            )
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(model.providerError?.contains("API Key") == true)
        XCTAssertEqual(secrets.values[ProviderStore.account(for: .deepseek)], "sk-test")
        XCTAssertEqual(model.providerMetadata?.baseURL, "https://api.deepseek.com/v1")
    }

    func testValidationErrorIsSurfaced() {
        let model = makeModel()

        let saved = model.saveProvider(
            ProviderDraft(kind: .custom, baseURL: "not-a-url", model: "m", apiKey: "sk")
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(model.providerError?.contains("BaseURL") == true)
        XCTAssertNil(model.providerMetadata)
    }

    func testDeletingActiveProviderClearsMetadataAndSecret() {
        let model = makeModel()
        model.saveProvider(deepseekDraft())

        model.deleteProvider(.deepseek)

        XCTAssertNil(model.providerMetadata)
        XCTAssertNil(model.activeProvider)
        XCTAssertNil(secrets.values[ProviderStore.account(for: .deepseek)])
    }

    func testMissingKeyIsReportedInsteadOfFallingBackToMock() {
        let model = makeModel()
        model.saveProvider(deepseekDraft())
        secrets.values[ProviderStore.account(for: .deepseek)] = nil

        XCTAssertNil(model.providerMetadata)
        XCTAssertTrue(model.providerIncompleteMessage?.contains("API Key") == true)
        XCTAssertTrue(model.providerSummary.contains("不完整"))
        XCTAssertFalse(model.hasConfiguredProvider)
    }

    func testCheckProviderReportsInvalidKey() async {
        let model = makeModel(probe: ProviderProbe(transport: StubTransport(statusCode: 401)))
        model.confirmProviderDataNotice()

        await model.checkProvider(deepseekDraft())

        XCTAssertNil(model.providerError)
        XCTAssertTrue(model.providerCheckMessage?.contains("API Key") == true)
        XCTAssertFalse(model.isCheckingProvider)
    }
}
