import Foundation
import XCTest

@testable import RoundtableCore

@MainActor
final class RoundtableRepositoryTests: XCTestCase {
    func testRestoresMessagesCursorAndVisibleMessageAfterRestart() throws {
        let store = InMemoryRoomStore()
        let first = makeRepository(store: store)
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try first.present(room.roundtable, cursor: 0)
        let messageEvent = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "message.completed",
                sequence: 1,
                payload: "{\"message\": \(Fixtures.messageJSON)}"
            )
        )
        try first.apply(messageEvent)
        try first.markVisibleMessage(Fixtures.messageID)

        let restarted = makeRepository(store: store)
        XCTAssertTrue(try restarted.restoreRecent())
        XCTAssertEqual(restarted.room?.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(restarted.room?.lastSequence, 1)
        XCTAssertEqual(restarted.room?.lastVisibleMessageID, Fixtures.messageID)
    }

    func testRestoredEventIDsPreventDuplicateRenderingAfterRestart() throws {
        let store = InMemoryRoomStore()
        let first = makeRepository(store: store)
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try first.present(room.roundtable, cursor: 0)
        let messageEvent = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "message.completed",
                sequence: 1,
                payload: "{\"message\": \(Fixtures.messageJSON)}"
            )
        )
        try first.apply(messageEvent)

        let restarted = makeRepository(store: store)
        XCTAssertTrue(try restarted.restoreRecent())
        try restarted.apply(messageEvent)

        XCTAssertEqual(restarted.room?.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(restarted.room?.lastSequence, 1)
    }

    func testRestoresCompletedSummaryAfterRestart() throws {
        let store = InMemoryRoomStore()
        let first = makeRepository(store: store)
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try first.present(room.roundtable, cursor: 0)
        try first.apply(
            try EventEnvelope.decode(
                from: Fixtures.envelope(
                    eventType: "summary.completed",
                    sequence: 1,
                    payload: "{\"summary\": \(Fixtures.summaryJSON)}"
                )
            )
        )

        let restarted = makeRepository(store: store)
        XCTAssertTrue(try restarted.restoreRecent())
        XCTAssertEqual(restarted.room?.status, .completed)
        XCTAssertEqual(restarted.room?.summary?.id, Fixtures.summaryID)
        XCTAssertEqual(restarted.room?.summary?.degraded, false)
    }

    private func makeRepository(store: InMemoryRoomStore) -> RoundtableRepository {
        RoundtableRepository(
            api: APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!),
            store: store
        )
    }
}

@MainActor
private final class InMemoryRoomStore: RoundtableRoomStore {
    private var rooms: [UUID: StoredRoomState] = [:]

    func save(_ state: StoredRoomState) throws {
        rooms[state.snapshot.id] = state
    }

    func load(roomID: UUID) throws -> StoredRoomState? {
        rooms[roomID]
    }

    func loadMostRecent() throws -> StoredRoomState? {
        rooms.values.max { $0.savedAt < $1.savedAt }
    }

    func delete(roomID: UUID) throws {
        rooms[roomID] = nil
    }
}
