import XCTest

final class UserControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUserCanMentionPauseResumeAndEnd() throws {
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
        topic.typeText("团队只有两个人时该不该压缩验证周期？")
        app.startRoundtable()

        XCTAssertTrue(
            element(in: app, "room.empty").waitForExistence(timeout: 25),
            app.debugDescription
        )

        let input = element(in: app, "room.user-message.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        app.buttons["room.user-message.mention"].tap()
        let experience = app.buttons["AI · 体验派"]
        XCTAssertTrue(experience.waitForExistence(timeout: 5))
        experience.tap()

        input.tap()
        input.typeText("体验派先补充用户侧影响。")
        let send = app.buttons["room.user-message.send"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: send
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 5),
            .completed,
            "发送按钮没有在输入完成后启用：\(app.debugDescription)"
        )
        send.tap()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "体验派先补充用户侧影响")
            ).firstMatch.waitForExistence(timeout: 15),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 10))

        app.buttons["room.resume"].tap()
        XCTAssertTrue(app.staticTexts["讨论中"].waitForExistence(timeout: 10))

        app.buttons["room.pause"].tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 10))

        app.buttons["room.end"].tap()
        XCTAssertTrue(app.staticTexts["已结束"].waitForExistence(timeout: 10))
    }

    private func element(in app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
