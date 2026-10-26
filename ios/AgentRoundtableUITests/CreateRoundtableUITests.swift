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
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()

        let topic = app.descendants(matching: .any).matching(identifier: "create.topic").firstMatch
        XCTAssertTrue(
            topic.waitForExistence(timeout: 20),
            "议题输入框没有出现：\(app.debugDescription)"
        )
        topic.tap()
        topic.typeText("该不该把验证周期压缩到两周？")

        let start = app.buttons["create.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled, "填了议题、选满 3 个 Agent 后按钮仍然不可用")
        start.tap()

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
            NSPredicate(format: "label CONTAINS %@", "引用 方案派 的原观点")
        ).firstMatch
        XCTAssertTrue(
            quotedClaim.waitForExistence(timeout: 25),
            "第二轮没有展示被引用观点的作者与原内容：\(app.debugDescription)"
        )
        let challengeTarget = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "向 方案派 提出质疑")
        ).firstMatch
        XCTAssertTrue(
            challengeTarget.waitForExistence(timeout: 10),
            "挑战关系没有展示明确对象：\(app.debugDescription)"
        )
        attachScreenshot(of: app, named: "03-mock-round-two-review")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
