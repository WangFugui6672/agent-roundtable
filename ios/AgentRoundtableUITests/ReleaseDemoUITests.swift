import XCTest

final class ReleaseDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Release smoke and recording flow:
    /// create -> first mock round -> user mention -> resume -> second round -> summary card.
    func testReleaseDemoFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
        app.launch()
        app.openCreateIfNeeded()

        let topic = app.descendants(matching: .any).matching(identifier: "create.topic").firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 20), app.debugDescription)
        topic.tap()
        topic.typeText("独立开发者该不该先做 iOS 再补 Android？")

        app.startRoundtable()

        XCTAssertTrue(
            app.staticTexts["room.empty"].waitForExistence(timeout: 25),
            app.debugDescription
        )
        attachScreenshot(named: "01-created-room", app: app)

        app.buttons["room.mock"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "先用一个两周的验证性实验")
            ).firstMatch.waitForExistence(timeout: 25),
            app.debugDescription
        )
        attachScreenshot(named: "02-first-round", app: app)

        app.buttons["room.user-message.mention"].tap()
        let experience = app.buttons["AI · 体验派"]
        XCTAssertTrue(experience.waitForExistence(timeout: 5))
        experience.tap()

        let input = app.descendants(matching: .any)
            .matching(identifier: "room.user-message.input")
            .firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("请体验派先补充真实用户的学习成本。")
        app.buttons["room.user-message.send"].tap()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "学习成本")
            ).firstMatch.waitForExistence(timeout: 15),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 10))
        attachScreenshot(named: "03-user-interjection", app: app)

        app.buttons["room.resume"].tap()
        XCTAssertTrue(app.staticTexts["讨论中"].waitForExistence(timeout: 10))
        app.buttons["room.mock"].tap()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "引用 AI · 方案派 的原观点")
            ).firstMatch.waitForExistence(timeout: 25),
            app.debugDescription
        )
        attachScreenshot(named: "04-second-round", app: app)

        let degraded = app.staticTexts["summary.degraded"]
        app.scrollUntilExists(degraded)
        XCTAssertTrue(degraded.waitForExistence(timeout: 25), app.debugDescription)
        let cardButton = app.buttons["summary.card.open"]
        scrollToElement(cardButton, in: app)
        XCTAssertTrue(cardButton.waitForExistence(timeout: 5))
        cardButton.tap()
        XCTAssertTrue(
            app.images["summary.card.preview"].waitForExistence(timeout: 15),
            app.debugDescription
        )
        attachScreenshot(named: "05-summary-card", app: app)
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 8 where !element.isHittable {
            app.swipeUp()
        }
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
