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
        attachScreenshot(of: app, named: "01-empty-roundtable")

        let mock = app.buttons["room.mock"]
        XCTAssertTrue(mock.waitForExistence(timeout: 5))
        mock.tap()

        let claim = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "先用一个两周的验证性实验")
        ).firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 25), "Mock 事件没有被客户端解码并渲染")
        attachScreenshot(of: app, named: "02-mock-round")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
