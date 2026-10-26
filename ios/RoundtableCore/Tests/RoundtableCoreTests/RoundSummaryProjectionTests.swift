import XCTest

@testable import RoundtableCore

@MainActor
final class RoundSummaryProjectionTests: XCTestCase {
    func testSummaryEventsEnterSummarizingThenCompletedAndKeepStructuredResult() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.joinedEnvelope))

        model.apply(
            try envelope("summary.started", 1, "{\"round\": 2}")
        )
        XCTAssertEqual(model.status, .summarizing)
        XCTAssertNil(model.summary)

        model.apply(
            try envelope(
                "summary.completed",
                2,
                "{\"summary\": \(Fixtures.summaryJSON)}"
            )
        )
        XCTAssertEqual(model.status, .completed)
        XCTAssertEqual(model.summary?.id, Fixtures.summaryID)
        XCTAssertEqual(model.summary?.consensus.first?.referenceMessageIds, [Fixtures.messageID])
    }

    private func envelope(_ type: String, _ sequence: Int, _ payload: String) throws
        -> EventEnvelope {
        try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: type,
                sequence: sequence,
                payload: payload,
                eventID: UUID()
            )
        )
    }
}
