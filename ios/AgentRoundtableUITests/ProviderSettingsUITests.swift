import XCTest

final class ProviderSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Issue #3 acceptance: three presets, save a custom provider, see it on the
    /// create screen, then delete it and confirm the Keychain-backed status is gone.
    func testSavesAndDeletesCustomProvider() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()
        app.openCreateIfNeeded()

        let providerEntry = app.buttons["create.provider"]
        XCTAssertTrue(
            providerEntry.waitForExistence(timeout: 20),
            "创建页没有出现 Provider 入口：\(app.debugDescription)"
        )
        providerEntry.tap()

        let segmented = app.segmentedControls.firstMatch
        XCTAssertTrue(segmented.waitForExistence(timeout: 5))
        for preset in ["通义千问", "DeepSeek", "自定义"] {
            XCTAssertTrue(segmented.buttons[preset].exists, "缺少 \(preset) 预设")
        }

        segmented.buttons["自定义"].tap()

        type("https://example.com/v1", into: app.textFields["provider.baseURL"])
        type("ui-test-model", into: app.textFields["provider.model"])
        type("sk-ui-test-key", into: app.secureTextFields["provider.apiKey"])

        dismissKeyboard(in: app)
        app.buttons["provider.save"].tap()

        XCTAssertTrue(
            element(in: app, "provider.status").waitForExistence(timeout: 5),
            "保存后没有显示 Keychain 状态：\(app.debugDescription)"
        )

        app.buttons["provider.done"].tap()

        let summary = app.buttons["create.provider"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            summary.label.contains("ui-test-model"),
            "创建页没有显示已保存的 Provider：\(summary.label)"
        )

        summary.tap()
        let delete = app.buttons["provider.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        app.buttons["删除"].tap()

        XCTAssertTrue(
            element(in: app, "provider.checkResult").waitForExistence(timeout: 5),
            "删除后没有反馈：\(app.debugDescription)"
        )
        XCTAssertFalse(element(in: app, "provider.status").exists)
    }

    private func element(in app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "找不到输入框：\(field)")
        field.tap()
        field.typeText(text)
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        if app.buttons["provider.dismissKeyboard"].exists {
            app.buttons["provider.dismissKeyboard"].tap()
        }
    }
}
