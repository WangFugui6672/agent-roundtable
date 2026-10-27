import XCTest

@testable import RoundtableCore

@MainActor
extension RoundtableRoomModelTests {
    func testLocalFlagHideAndReportStatePersistsWithoutDeletingMessages() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        model.apply(
            try envelope("message.completed", 1, "{\"message\": \(Fixtures.messageJSON)}")
        )

        model.flagMessage(Fixtures.messageID)
        model.hideMessage(Fixtures.messageID)
        model.markMessageReported(Fixtures.messageID)
        let state = model.storedState(savedAt: Date())
        let restored = RoundtableRoomModel()
        restored.restore(state)

        XCTAssertEqual(restored.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(restored.flaggedMessageIDs, [Fixtures.messageID])
        XCTAssertEqual(restored.hiddenMessageIDs, [Fixtures.messageID])
        XCTAssertEqual(restored.reportedMessageIDs, [Fixtures.messageID])
    }

    func testFlaggedSummarySurvivesRestore() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        model.apply(
            try envelope(
                "summary.completed",
                1,
                "{\"summary\": \(Fixtures.summaryJSON)}"
            )
        )
        model.flagSummary(Fixtures.summaryID)

        let restored = RoundtableRoomModel()
        restored.restore(model.storedState(savedAt: Date()))

        XCTAssertEqual(restored.flaggedSummaryIDs, [Fixtures.summaryID])
    }
}
