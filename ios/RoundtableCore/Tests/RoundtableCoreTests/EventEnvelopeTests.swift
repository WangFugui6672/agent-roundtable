import XCTest

@testable import RoundtableCore

final class EventEnvelopeTests: XCTestCase {
    func testDecodesJoinSnapshot() throws {
        let envelope = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)

        XCTAssertEqual(envelope.eventId, Fixtures.eventID)
        XCTAssertEqual(envelope.roomId, Fixtures.roomID)
        XCTAssertEqual(envelope.sequence, 0)
        XCTAssertEqual(envelope.eventType, "room.joined")
        XCTAssertEqual(
            envelope.createdAt.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_792_976_523.456).timeIntervalSince1970,
            accuracy: 0.001
        )

        guard case let .joined(joined) = envelope.payload else {
            return XCTFail("expected a joined payload, got \(envelope.payload)")
        }
        XCTAssertEqual(joined.messages, [])
        XCTAssertEqual(joined.roundtable.topic, "该不该把验证周期压缩到两周？")
        XCTAssertEqual(joined.roundtable.status, .ready)
        XCTAssertEqual(joined.roundtable.participants.count, 3)
        XCTAssertEqual(joined.roundtable.participants[0].agent.name, "方案派")
        XCTAssertEqual(joined.roundtable.participants[0].position, 0)
        XCTAssertEqual(joined.roundtable.lastSequence, 0)
    }

    func testDecodesCompletedMessage() throws {
        let data = Fixtures.envelope(
            eventType: "message.completed",
            sequence: 4,
            payload: "{\"message\": \(Fixtures.messageJSON)}"
        )

        let envelope = try EventEnvelope.decode(from: data)

        guard case let .messageCompleted(message) = envelope.payload else {
            return XCTFail("expected a completed message, got \(envelope.payload)")
        }
        XCTAssertEqual(message.id, Fixtures.messageID)
        XCTAssertEqual(message.turnId, Fixtures.turnID)
        XCTAssertEqual(message.roundNumber, 1)
        XCTAssertEqual(message.author.name, "方案派")
        XCTAssertEqual(message.author.agentKey, "advocate")
        XCTAssertEqual(message.author.roundtableAgentId, Fixtures.advocateID)
        XCTAssertEqual(message.messageType, .proposal)
        XCTAssertNil(message.stance)
        XCTAssertEqual(message.references, [])
        XCTAssertEqual(message.confidence ?? 0, 0.72, accuracy: 0.0001)
    }

    func testDecodesUserAuthoredMessageWithoutAnAgentIdentity() throws {
        let data = Fixtures.envelope(
            eventType: "message.completed",
            sequence: 4,
            payload: "{\"message\": \(Fixtures.userMessageJSON)}"
        )

        let envelope = try EventEnvelope.decode(from: data)

        guard case let .messageCompleted(message) = envelope.payload else {
            return XCTFail("expected a completed message, got \(envelope.payload)")
        }
        XCTAssertEqual(message.author.type, .user)
        XCTAssertNil(message.author.roundtableAgentId)
        XCTAssertNil(message.author.agentKey)
        XCTAssertEqual(message.messageType, .userMessage)
        XCTAssertNil(message.claim)
        XCTAssertNil(message.confidence)
        XCTAssertEqual(message.mentionedAgentIds, [Fixtures.advocateID])
    }

    func testDecodesPausePendingTurnIdentity() throws {
        let data = Fixtures.envelope(
            eventType: "room.pause_pending",
            sequence: 4,
            payload: "{\"turn_id\": \"\(Fixtures.turnID.uuidString)\"}"
        )

        let envelope = try EventEnvelope.decode(from: data)

        guard case let .pausePending(pending) = envelope.payload else {
            return XCTFail("expected room.pause_pending, got \(envelope.payload)")
        }
        XCTAssertEqual(pending.turnId, Fixtures.turnID)
    }

    func testDecodesRoomControlStateEvents() throws {
        let paused = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "room.paused",
                sequence: 5,
                payload: "{\"status\": \"paused\"}"
            )
        )
        let resumed = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "room.resumed",
                sequence: 6,
                payload: "{\"status\": \"running\"}"
            )
        )
        let ended = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "room.ended",
                sequence: 7,
                payload: "{\"status\": \"completed\"}"
            )
        )

        guard case let .paused(pausedState) = paused.payload,
              case let .resumed(resumedState) = resumed.payload,
              case let .ended(endedState) = ended.payload
        else {
            return XCTFail("expected room control events")
        }
        XCTAssertEqual(pausedState.status, .paused)
        XCTAssertEqual(resumedState.status, .running)
        XCTAssertEqual(endedState.status, .completed)
    }

    func testKeepsUnknownEventTypesForForwardCompatibility() throws {
        let data = Fixtures.envelope(eventType: "future.thing", sequence: 9, payload: "{\"x\": 1}")

        let envelope = try EventEnvelope.decode(from: data)

        XCTAssertEqual(envelope.eventType, "future.thing")
        XCTAssertEqual(envelope.payload, .unknown)
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try EventEnvelope.decode(from: Data("not json".utf8)))
    }

    func testAcceptsTimestampsWithoutFractionalSeconds() throws {
        let data = Data("""
        {
          "event_id": "0F9A0000-0000-4000-8000-000000000002",
          "room_id": "C0DEC0DE-0000-4000-8000-000000000001",
          "sequence": 1,
          "created_at": "2026-10-26T01:02:03Z",
          "event_type": "round.started",
          "payload": {"round": 1, "max_rounds": 2, "topic": "t"}
        }
        """.utf8)

        let envelope = try EventEnvelope.decode(from: data)

        guard case let .roundStarted(started) = envelope.payload else {
            return XCTFail("expected round.started, got \(envelope.payload)")
        }
        XCTAssertEqual(started.round, 1)
        XCTAssertEqual(started.maxRounds, 2)
    }
}
