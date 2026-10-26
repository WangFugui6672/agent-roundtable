import XCTest

final class RealTurnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Issue #4 acceptance: a failing provider shows a readable reason instead
    /// of silently falling back, and nothing is submitted to the backend.
    func testUnreachableProviderShowsError() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()

        let providerEntry = app.buttons["create.provider"]
        XCTAssertTrue(
            providerEntry.waitForExistence(timeout: 20),
            "创建页没有出现 Provider 入口：\(app.debugDescription)"
        )
        providerEntry.tap()

        app.segmentedControls.firstMatch.buttons["自定义"].tap()
        type("http://127.0.0.1:9/v1", into: app.textFields["provider.baseURL"])
        type("unreachable-model", into: app.textFields["provider.model"])
        type("sk-ui-test-key", into: app.secureTextFields["provider.apiKey"])
        dismissKeyboard(in: app)
        app.buttons["provider.save"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "provider.status").firstMatch
                .waitForExistence(timeout: 5)
        )
        app.buttons["provider.done"].tap()

        let topic = app.descendants(matching: .any).matching(identifier: "create.topic").firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 5))
        topic.tap()
        topic.typeText("该不该把验证周期压缩到两周？")
        dismissKeyboard(in: app)
        app.buttons["create.start"].tap()

        XCTAssertTrue(
            app.staticTexts["room.empty"].waitForExistence(timeout: 25),
            "没有进入空圆桌：\(app.debugDescription)"
        )

        let startRound = app.buttons["room.round.start"]
        XCTAssertTrue(startRound.waitForExistence(timeout: 5))
        startRound.tap()

        let error = app.descendants(matching: .any).matching(identifier: "room.turn.error").firstMatch
        XCTAssertTrue(
            error.waitForExistence(timeout: 30),
            "Provider 失败后没有显示错误：\(app.debugDescription)"
        )
        XCTAssertTrue(
            error.label.contains("网络") || error.label.contains("Provider"),
            "错误信息不明确：\(error.label)"
        )
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
