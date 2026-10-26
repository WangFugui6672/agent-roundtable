import XCTest

@testable import RoundtableCore

@MainActor
final class RoundtableRoomModelTests: XCTestCase {
    private func joinedEnvelope() throws -> EventEnvelope {
        try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
    }

    private func envelope(_ type: String, _ sequence: Int, _ payload: String) throws -> EventEnvelope {
        try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: type,
                sequence: sequence,
                payload: payload,
                eventID: UUID()
            )
        )
    }

    func testJoinPopulatesParticipantsWithoutAdvancingCursor() throws {
        let model = RoundtableRoomModel()

        model.apply(try joinedEnvelope())

        XCTAssertEqual(model.participants.count, 3)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.currentRound, 0)
        XCTAssertEqual(model.lastSequence, 0, "room.joined must not move the resume cursor")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testMessageCompletedAppendsAndAdvancesCursor() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(
            try envelope("message.completed", 4, "{\"message\": \(Fixtures.messageJSON)}")
        )

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages[0].id, Fixtures.messageID)
        XCTAssertEqual(model.lastSequence, 4)
        XCTAssertEqual(model.participants[0].state, .completed)
        XCTAssertNil(model.activeParticipantId)
    }

    func testDuplicateEventIsIgnored() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        let duplicate = try envelope("message.completed", 4, "{\"message\": \(Fixtures.messageJSON)}")

        model.apply(duplicate)
        model.apply(duplicate)

        XCTAssertEqual(model.messages.count, 1)
    }

    func testStaleSequenceIsIgnored() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        model.apply(
            try envelope("message.completed", 4, "{\"message\": \(Fixtures.messageJSON)}")
        )

        model.apply(try envelope("agent.thinking", 2, "{\"agent_id\": \"\(Fixtures.advocateID.uuidString)\"}"))

        XCTAssertEqual(model.lastSequence, 4)
        XCTAssertEqual(model.messages.count, 1)
    }

    func testThinkingUpdatesParticipantState() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(
            try envelope(
                "agent.thinking",
                1,
                "{\"agent_id\": \"\(Fixtures.advocateID.uuidString)\", \"agent_name\": \"方案派\"}"
            )
        )

        XCTAssertEqual(model.participants[0].state, .thinking)
        XCTAssertEqual(model.activeParticipantId, Fixtures.advocateID)
    }

    func testRoundCompletedInfersRunningStatus() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(try envelope("round.started", 1, "{\"round\": 1, \"max_rounds\": 2}"))
        model.apply(try envelope("round.completed", 11, "{\"round\": 1}"))

        XCTAssertEqual(model.currentRound, 1)
        XCTAssertEqual(model.status, .running)
        XCTAssertEqual(model.lastSequence, 11)
    }

    func testUnknownEventAdvancesCursorWithoutRendering() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(try envelope("future.thing", 3, "{\"x\": 1}"))

        XCTAssertEqual(model.lastSequence, 3, "an ignored event must still move the cursor")
        XCTAssertTrue(model.messages.isEmpty)
    }
}
