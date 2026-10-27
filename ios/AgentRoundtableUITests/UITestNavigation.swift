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
}
