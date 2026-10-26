import XCTest

final class RecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProcessRelaunchRestoresCachedRoundtableAndMessages() throws {
        let topic = "进程终止后恢复圆桌和滚动上下文"
        let message = "这条消息需要在重启后继续可见。"
        let first = XCUIApplication()
        first.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        first.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        first.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        first.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        first.launch()

        let topicField = first.descendants(matching: .any)
            .matching(identifier: "create.topic")
            .firstMatch
        XCTAssertTrue(topicField.waitForExistence(timeout: 20), first.debugDescription)
        topicField.tap()
        topicField.typeText(topic)
        first.buttons["create.start"].tap()

        XCTAssertTrue(
            first.staticTexts["room.empty"].waitForExistence(timeout: 25),
            first.debugDescription
        )
        let input = first.descendants(matching: .any)
            .matching(identifier: "room.user-message.input")
            .firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(message)
        first.buttons["room.user-message.send"].tap()
        XCTAssertTrue(
            first.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", message)
            ).firstMatch.waitForExistence(timeout: 15),
            first.debugDescription
        )

        first.terminate()

        let restored = XCUIApplication()
        restored.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        restored.launch()

        XCTAssertTrue(
            restored.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", topic)
            ).firstMatch.waitForExistence(timeout: 10),
            restored.debugDescription
        )
        XCTAssertTrue(
            restored.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", message)
            ).firstMatch.waitForExistence(timeout: 10),
            restored.debugDescription
        )
    }
}
