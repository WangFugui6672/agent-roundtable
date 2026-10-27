import XCTest

final class SafetyPrivacyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAiLabelsPrivacyHideReportAndDelete() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()
        app.openCreateIfNeeded()

        let topic = element(in: app, "create.topic")
        XCTAssertTrue(topic.waitForExistence(timeout: 20), app.debugDescription)
        topic.tap()
        topic.typeText("隐私设置应该如何影响圆桌讨论？")
        app.buttons["create.start"].tap()
        XCTAssertTrue(
            element(in: app, "room.empty").waitForExistence(timeout: 25),
            app.debugDescription
        )

        app.buttons["room.mock"].tap()
        let claim = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "先用一个两周的验证性实验")
        ).firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 25), app.debugDescription)
        let aiParticipant = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "AI 参与者 方案派")
        ).firstMatch
        XCTAssertTrue(aiParticipant.exists, "参与者卡片没有明确 AI 标识")

        app.buttons["room.privacy"].tap()
        XCTAssertTrue(app.staticTexts["90 天保留"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()

        let messageMenu = app.buttons.matching(identifier: "room.message.menu").firstMatch
        XCTAssertTrue(messageMenu.waitForExistence(timeout: 5), app.debugDescription)
        messageMenu.tap()
        app.buttons["仅在本机隐藏"].tap()
        XCTAssertTrue(element(in: app, "room.hidden.toggle").waitForExistence(timeout: 5))

        element(in: app, "room.hidden.toggle").tap()
        app.buttons.matching(identifier: "room.message.menu").firstMatch.tap()
        app.buttons["举报"].tap()
        app.buttons["仇恨内容"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "举报已提交给维护者")
            ).firstMatch.waitForExistence(timeout: 10),
            app.debugDescription
        )

        app.buttons["room.delete"].tap()
        app.buttons["删除圆桌和本机缓存"].tap()
        XCTAssertTrue(
            app.buttons["home.create"].waitForExistence(timeout: 15),
            "删除后没有回到首页：\(app.debugDescription)"
        )
        app.terminate()
        let restored = XCUIApplication()
        restored.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        restored.launch()
        XCTAssertTrue(restored.buttons["home.create"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            restored.staticTexts["隐私设置应该如何影响圆桌讨论？"].exists,
            "服务端已删除的圆桌不能从本地缓存复活"
        )
    }

    func testThirdPartyNoticeAppearsBeforeRealProviderUseAndCanBeCancelled() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()
        app.openCreateIfNeeded()

        XCTAssertTrue(
            app.buttons["create.provider"].waitForExistence(timeout: 20),
            app.debugDescription
        )
        app.buttons["create.provider"].tap()
        app.segmentedControls.buttons["自定义"].tap()
        app.textFields["provider.baseURL"].tap()
        app.textFields["provider.baseURL"].typeText("https://example.com/v1")
        app.textFields["provider.model"].tap()
        app.textFields["provider.model"].typeText("ui-test-model")
        app.secureTextFields["provider.apiKey"].tap()
        app.secureTextFields["provider.apiKey"].typeText("sk-ui-test-key")
        if app.buttons["provider.dismissKeyboard"].exists {
            app.buttons["provider.dismissKeyboard"].tap()
        }
        for _ in 0 ..< 3 where !app.buttons["provider.save"].isHittable {
            app.swipeUp()
        }
        app.buttons["provider.save"].tap()
        app.buttons["provider.done"].tap()

        let topic = element(in: app, "create.topic")
        topic.tap()
        topic.typeText("是否应该使用真实模型讨论这个议题？")
        app.buttons["create.start"].tap()
        XCTAssertTrue(
            element(in: app, "room.empty").waitForExistence(timeout: 25),
            app.debugDescription
        )
        app.buttons["room.round.start"].tap()

        XCTAssertTrue(
            element(in: app, "provider.dataNotice.title").waitForExistence(timeout: 5),
            "真实 Provider 首次调用前没有显示第三方数据提示"
        )
        app.buttons["provider.dataNotice.cancel"].tap()
        XCTAssertFalse(element(in: app, "provider.dataNotice.title").exists)
        XCTAssertTrue(element(in: app, "room.empty").exists)
    }

    private func element(in app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
