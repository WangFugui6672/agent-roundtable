import XCTest

extension XCUIApplication {
    func openCreateIfNeeded(file: StaticString = #filePath, line: UInt = #line) {
        let create = buttons["home.create"]
        if create.waitForExistence(timeout: 15) {
            create.tap()
        }
        XCTAssertTrue(
            descendants(matching: .any)
                .matching(identifier: "create.topic")
                .firstMatch
                .waitForExistence(timeout: 15),
            "创建页没有出现：\(debugDescription)",
            file: file,
            line: line
        )
    }

    func startRoundtable(file: StaticString = #filePath, line: UInt = #line) {
        let start = buttons["create.start"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 10),
            "开始讨论按钮没有出现：\(debugDescription)",
            file: file,
            line: line
        )
        if keyboards.firstMatch.exists {
            // Xcode 16 can report a partially off-screen button as hittable.
            // Dismiss the keyboard and bring the action fully into view first.
            swipeUp()
        }
        for _ in 0 ..< 6 where !start.isHittable {
            swipeUp()
        }
        XCTAssertTrue(
            start.isHittable,
            "开始讨论按钮不可点击：\(debugDescription)",
            file: file,
            line: line
        )
        start.tap()
    }

    @discardableResult
    func scrollUntilExists(
        _ element: XCUIElement,
        maxSwipes: Int = 10
    ) -> Bool {
        for _ in 0 ..< maxSwipes {
            if element.exists {
                return true
            }
            swipeUp()
        }
        return element.exists
    }
}
