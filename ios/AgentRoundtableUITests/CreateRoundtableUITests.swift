import XCTest

final class CreateRoundtableUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs the slice end to end against a locally running backend:
    /// create → empty roundtable → one mock round.
    func testCreateRoundtableAndPlayMockRound() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()
        app.openCreateIfNeeded()

        let topic = app.descendants(matching: .any).matching(identifier: "create.topic").firstMatch
        XCTAssertTrue(
            topic.waitForExistence(timeout: 20),
            "议题输入框没有出现：\(app.debugDescription)"
        )
        topic.tap()
        topic.typeText("该不该把验证周期压缩到两周？")

        app.startRoundtable()

        let emptyRoom = app.staticTexts["room.empty"]
        XCTAssertTrue(
            emptyRoom.waitForExistence(timeout: 25),
            "没有进入空圆桌：\(app.debugDescription)"
        )
        let budget = app.descendants(matching: .any).matching(identifier: "room.budget").firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout: 5))
        XCTAssertTrue(budget.label.contains("0/6"))
        attachScreenshot(of: app, named: "01-empty-roundtable")

        let mock = app.buttons["room.mock"]
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()

        let claim = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "先用一个两周的验证性实验")
        ).firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 25), "Mock 事件没有被客户端解码并渲染")
        attachScreenshot(of: app, named: "02-mock-round")

        XCTAssertTrue(mock.isEnabled)
        mock.tap()

        let quotedClaim = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "引用 AI · 方案派 的原观点")
        ).firstMatch
        app.scrollUntilExists(quotedClaim)
        XCTAssertTrue(
            quotedClaim.waitForExistence(timeout: 25),
            "第二轮没有展示被引用观点的作者与原内容：\(app.debugDescription)"
        )
        let challengeTarget = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "向 方案派 提出质疑")
        ).firstMatch
        app.scrollUntilExists(challengeTarget)
        XCTAssertTrue(
            challengeTarget.waitForExistence(timeout: 10),
            "挑战关系没有展示明确对象：\(app.debugDescription)"
        )
        attachScreenshot(of: app, named: "03-mock-round-two-review")
        try assertSummaryCardAndRestart(app)
    }

    private func assertSummaryCardAndRestart(_ app: XCUIApplication) throws {
        let degraded = app.staticTexts["summary.degraded"]
        app.scrollUntilExists(degraded)
        XCTAssertTrue(
            degraded.waitForExistence(timeout: 25),
            "第二轮后没有自动进入降级总结：\(app.debugDescription)"
        )
        let cardButton = app.buttons["summary.card.open"]
        scrollToElement(cardButton, in: app)
        XCTAssertTrue(cardButton.waitForExistence(timeout: 5))
        cardButton.tap()
        XCTAssertTrue(
            app.images["summary.card.preview"].waitForExistence(timeout: 15),
            "ImageRenderer 没有生成结论卡：\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["summary.card.save"].exists)
        XCTAssertTrue(app.buttons["summary.card.share"].exists)
        XCTAssertTrue(app.buttons["follow-up.create"].exists)
        XCTAssertTrue(
            app.textFields["follow-up.topic"].exists
                || app.textViews["follow-up.topic"].exists
        )
        attachScreenshot(of: app, named: "04-summary-card")
        app.buttons["关闭"].tap()

        app.terminate()
        let restored = XCUIApplication()
        restored.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        restored.launch()
        let historyTopic = restored.staticTexts["该不该把验证周期压缩到两周？"]
        XCTAssertTrue(historyTopic.waitForExistence(timeout: 15), restored.debugDescription)
        historyTopic.tap()
        let restoredCard = restored.buttons["summary.card.open"]
        scrollToElement(restoredCard, in: restored)
        XCTAssertTrue(
            restoredCard.waitForExistence(timeout: 15),
            "进程重启后没有恢复已完成结论：\(restored.debugDescription)"
        )
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 where !element.isHittable {
            app.swipeUp()
        }
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
