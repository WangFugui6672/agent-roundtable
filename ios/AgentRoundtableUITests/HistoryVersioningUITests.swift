import XCTest

final class HistoryVersioningUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHistoryKeyPointAndRegenerationEntryAreUsable() throws {
        let app = XCUIApplication()
        configure(app)
        app.launch()
        app.openCreateIfNeeded()

        let topic = app.descendants(matching: .any)
            .matching(identifier: "create.topic")
            .firstMatch
        topic.tap()
        topic.typeText("历史、关键观点与重新生成")
        app.buttons["create.start"].tap()
        XCTAssertTrue(app.staticTexts["room.empty"].waitForExistence(timeout: 25))

        app.buttons["room.mock"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "先用一个两周的验证性实验")
            ).firstMatch.waitForExistence(timeout: 25),
            app.debugDescription
        )

        lastMessageMenu(in: app).tap()
        XCTAssertTrue(app.buttons["标记关键观点"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重新生成这条回复"].exists)
        app.buttons["标记关键观点"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "room.message.key-point")
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        lastMessageMenu(in: app).tap()
        app.buttons["重新生成这条回复"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "room.turn.error")
                .firstMatch
                .waitForExistence(timeout: 15),
            app.debugDescription
        )

        app.buttons["离开"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "历史、关键观点与重新生成")
            ).firstMatch.waitForExistence(timeout: 10),
            app.debugDescription
        )
    }

    func testAnonymousSessionCanRotateAndDeleteAllData() throws {
        let app = XCUIApplication()
        configure(app)
        app.launch()

        XCTAssertTrue(app.buttons["home.privacy"].waitForExistence(timeout: 20))
        app.buttons["home.privacy"].tap()
        XCTAssertTrue(app.buttons["privacy.session.rotate"].waitForExistence(timeout: 5))
        app.buttons["privacy.session.rotate"].tap()
        app.buttons["轮换标识"].tap()
        XCTAssertTrue(app.buttons["privacy.session.delete"].waitForExistence(timeout: 10))

        app.buttons["privacy.session.delete"].tap()
        app.buttons["删除全部数据"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["home.create"].waitForExistence(timeout: 15))
    }

    private func configure(_ app: XCUIApplication) {
        app.launchEnvironment["RT_API_BASE_URL"] = "http://localhost:8000"
        app.launchEnvironment["RT_RESET_PROVIDER_STATE"] = "1"
        app.launchEnvironment["RT_RESET_GUEST_SESSION"] = "1"
        app.launchEnvironment["RT_RESET_PERSISTED_ROOM"] = "1"
    }

    private func lastMessageMenu(in app: XCUIApplication) -> XCUIElement {
        let menus = app.buttons.matching(identifier: "room.message.menu")
        return menus.element(boundBy: max(0, menus.count - 1))
    }
}
