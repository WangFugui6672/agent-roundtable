import XCTest

@testable import RoundtableCore

@MainActor
final class RoundtableRoomModelTests: XCTestCase {
    func joinedEnvelope() throws -> EventEnvelope {
        try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
    }

    func envelope(_ type: String, _ sequence: Int, _ payload: String) throws -> EventEnvelope {
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

    func testJoinRestoresPendingTurnIdentity() throws {
        let model = RoundtableRoomModel()

        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))

        XCTAssertEqual(model.activeTurn?.turnId, Fixtures.turnID)
        XCTAssertEqual(model.activeTurn?.roundtableAgentId, Fixtures.advocateID)
    }

    func testNormalJoinDoesNotOverwriteThePersistedCursor() throws {
        let baseJoin = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(base) = baseJoin.payload else {
            return XCTFail("expected a joined payload")
        }
        let localSnapshot = RoundtableSnapshot(
            id: base.roundtable.id,
            topic: base.roundtable.topic,
            status: .running,
            mode: base.roundtable.mode,
            maxRounds: base.roundtable.maxRounds,
            currentRound: 1,
            lastSequence: 5,
            createdAt: base.roundtable.createdAt,
            updatedAt: base.roundtable.updatedAt,
            participants: base.roundtable.participants
        )
        let serverSnapshot = RoundtableSnapshot(
            id: base.roundtable.id,
            topic: base.roundtable.topic,
            status: .running,
            mode: base.roundtable.mode,
            maxRounds: base.roundtable.maxRounds,
            currentRound: 1,
            lastSequence: 8,
            createdAt: base.roundtable.createdAt,
            updatedAt: base.roundtable.updatedAt,
            participants: base.roundtable.participants
        )
        let model = RoundtableRoomModel()
        model.seed(localSnapshot, cursor: 3)

        model.apply(
            EventEnvelope(
                eventId: UUID(),
                roomId: Fixtures.roomID,
                sequence: 0,
                createdAt: Date(),
                eventType: "room.joined",
                payload: .joined(JoinedRoom(roundtable: serverSnapshot, messages: []))
            )
        )

        XCTAssertEqual(model.lastSequence, 3)
        XCTAssertEqual(model.snapshot?.lastSequence, 8)
    }

    func testExpiredCursorResetsProjectionToTheFullJoinSnapshot() throws {
        let baseJoin = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(base) = baseJoin.payload else {
            return XCTFail("expected a joined payload")
        }
        let oldSnapshot = RoundtableSnapshot(
            id: base.roundtable.id,
            topic: base.roundtable.topic,
            status: .running,
            mode: base.roundtable.mode,
            maxRounds: base.roundtable.maxRounds,
            currentRound: 1,
            lastSequence: 10,
            createdAt: base.roundtable.createdAt,
            updatedAt: base.roundtable.updatedAt,
            participants: base.roundtable.participants
        )
        let messageEnvelope = try envelope(
            "message.completed",
            11,
            "{\"message\": \(Fixtures.messageJSON)}"
        )
        guard case let .messageCompleted(message) = messageEnvelope.payload else {
            return XCTFail("expected a completed message")
        }
        let model = RoundtableRoomModel()
        model.seed(oldSnapshot)
        model.apply(messageEnvelope)

        let resetSnapshot = RoundtableSnapshot(
            id: oldSnapshot.id,
            topic: oldSnapshot.topic,
            status: .running,
            mode: oldSnapshot.mode,
            maxRounds: oldSnapshot.maxRounds,
            currentRound: 2,
            lastSequence: 20,
            createdAt: oldSnapshot.createdAt,
            updatedAt: oldSnapshot.updatedAt,
            participants: oldSnapshot.participants
        )
        let resetEnvelope = EventEnvelope(
            eventId: UUID(),
            roomId: Fixtures.roomID,
            sequence: 0,
            createdAt: Date(),
            eventType: "room.joined",
            payload: .joined(
                JoinedRoom(
                    roundtable: resetSnapshot,
                    messages: [message],
                    replay: ReplayMetadata(
                        requestedCursor: 10,
                        oldestSequence: 18,
                        latestSequence: 20,
                        windowDays: 90,
                        cursorExpired: true
                    )
                )
            )
        )

        model.apply(resetEnvelope)

        XCTAssertEqual(model.lastSequence, 20)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.currentRound, 2)
    }

    func testMatchingMessageCompletionClearsThePendingTurn() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))

        model.apply(
            try envelope("message.completed", 3, "{\"message\": \(Fixtures.messageJSON)}")
        )

        XCTAssertNil(model.activeTurn)
        XCTAssertEqual(model.messages.count, 1)
    }

    func testMessageCompletedAppendsAndAdvancesCursor() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(
            try envelope("message.completed", 1, "{\"message\": \(Fixtures.messageJSON)}")
        )

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages[0].id, Fixtures.messageID)
        XCTAssertEqual(model.lastSequence, 1)
        XCTAssertEqual(model.participants[0].state, .completed)
        XCTAssertNil(model.activeParticipantId)
    }

    func testDuplicateEventIsIgnored() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        let duplicate = try envelope("message.completed", 1, "{\"message\": \(Fixtures.messageJSON)}")

        model.apply(duplicate)
        model.apply(duplicate)

        XCTAssertEqual(model.messages.count, 1)
    }

    func testStaleSequenceIsIgnored() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))
        model.apply(
            try envelope("message.completed", 3, "{\"message\": \(Fixtures.messageJSON)}")
        )

        model.apply(try envelope("agent.thinking", 2, "{\"agent_id\": \"\(Fixtures.advocateID.uuidString)\"}"))

        XCTAssertEqual(model.lastSequence, 3)
        XCTAssertEqual(model.messages.count, 1)
    }

    func testOutOfOrderEventWaitsForTheMissingSequenceBeforeRendering() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())
        model.apply(try envelope("round.started", 1, "{\"round\": 1, \"max_rounds\": 2}"))
        let futureMessage = try envelope(
            "message.completed",
            3,
            "{\"message\": \(Fixtures.messageJSON)}"
        )

        model.apply(futureMessage)

        XCTAssertEqual(model.lastSequence, 1)
        XCTAssertTrue(model.messages.isEmpty)

        model.apply(try envelope("future.thing", 2, "{\"x\": 1}"))

        XCTAssertEqual(model.lastSequence, 3)
        XCTAssertEqual(model.messages.map(\.id), [Fixtures.messageID])
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
        model.apply(try envelope("round.completed", 2, "{\"round\": 1}"))

        XCTAssertEqual(model.currentRound, 1)
        XCTAssertEqual(model.status, .running)
        XCTAssertEqual(model.lastSequence, 2)
    }

    func testUnknownEventAdvancesCursorWithoutRendering() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(try envelope("future.thing", 1, "{\"x\": 1}"))

        XCTAssertEqual(model.lastSequence, 1, "an ignored event must still move the cursor")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testPauseTakesEffectOnlyAfterTheCurrentTurnCompletes() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))

        model.apply(
            try envelope(
                "room.pause_pending",
                3,
                "{\"turn_id\": \"\(Fixtures.turnID.uuidString)\"}"
            )
        )

        XCTAssertTrue(model.pausePending)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.activeTurn?.turnId, Fixtures.turnID)

        model.apply(
            try envelope("message.completed", 4, "{\"message\": \(Fixtures.messageJSON)}")
        )
        XCTAssertNil(model.activeTurn)
        XCTAssertTrue(model.pausePending)

        model.apply(try envelope("room.paused", 5, "{\"status\": \"paused\"}"))
        XCTAssertFalse(model.pausePending)
        XCTAssertEqual(model.status, .paused)
    }

    func testUserMessageAppendsWithoutChangingAgentState() throws {
        let model = RoundtableRoomModel()
        model.apply(try joinedEnvelope())

        model.apply(
            try envelope("message.completed", 1, "{\"message\": \(Fixtures.userMessageJSON)}")
        )

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages[0].author.type, .user)
        XCTAssertEqual(model.participants.map(\.state), [.waiting, .waiting, .waiting])
    }

    func testEndClearsCancelledAgentActivity() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))
        XCTAssertEqual(model.participants[0].state, .waiting)
        model.apply(
            try envelope(
                "agent.thinking",
                3,
                """
                {
                  "turn_id": "\(Fixtures.turnID.uuidString)",
                  "round": 1,
                  "agent_id": "\(Fixtures.advocateID.uuidString)",
                  "agent_name": "方案派"
                }
                """
            )
        )
        XCTAssertEqual(model.participants[0].state, .thinking)

        model.apply(
            try envelope(
                "room.ended",
                4,
                """
                {
                  "status": "completed",
                  "cancelled_turn_id": "\(Fixtures.turnID.uuidString)",
                  "cancelled_agent_id": "\(Fixtures.advocateID.uuidString)"
                }
                """
            )
        )

        XCTAssertEqual(model.status, .completed)
        XCTAssertEqual(model.participants[0].state, .waiting)
        XCTAssertNil(model.activeTurn)
    }

    func testFailureIsAppliedOnceAndKeepsCompletedMessages() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.activeTurnJoinedEnvelope))
        model.apply(
            try envelope("message.completed", 3, "{\"message\": \(Fixtures.messageJSON)}")
        )
        let failure = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "agent.failed",
                sequence: 4,
                payload: """
                {
                  "turn_id": "\(Fixtures.turnID.uuidString)",
                  "round": 1,
                  "agent_id": "\(Fixtures.advocateID.uuidString)",
                  "agent_name": "方案派",
                  "failure_code": "provider_network",
                  "message": "网络请求失败。",
                  "retryable": true,
                  "partial": "已生成的半段"
                }
                """,
                eventID: UUID()
            )
        )
        let duplicate = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "agent.failed",
                sequence: 5,
                payload: """
                {
                  "turn_id": "\(Fixtures.turnID.uuidString)",
                  "round": 1,
                  "agent_id": "\(Fixtures.advocateID.uuidString)",
                  "agent_name": "方案派",
                  "failure_code": "provider_network",
                  "message": "网络请求失败。",
                  "retryable": true,
                  "partial": "已生成的半段"
                }
                """,
                eventID: UUID()
            )
        )

        model.apply(failure)
        model.apply(duplicate)

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.failures.count, 1)
        XCTAssertEqual(model.failures[0].partial, "已生成的半段")
        XCTAssertEqual(model.participants[0].state, .failed)
        XCTAssertNil(model.activeTurn)
    }

}

extension RoundtableRoomModelTests {
    func testBudgetExhaustionCompletesTheRoomOnce() throws {
        let model = RoundtableRoomModel()
        model.apply(try EventEnvelope.decode(from: Fixtures.joinedEnvelope))
        let budget = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "budget.exhausted",
                sequence: 1,
                payload: """
                {"reason": "duration", "message": "讨论已达到 90 秒时间上限。", "round": 1}
                """,
                eventID: UUID()
            )
        )

        model.apply(budget)
        model.apply(budget)

        XCTAssertEqual(model.status, .completed)
        XCTAssertEqual(model.budgetExhaustion?.reason, .duration)
        XCTAssertEqual(model.lastSequence, 1)
    }
}
