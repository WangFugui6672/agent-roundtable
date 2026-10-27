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

    func testIgnoresSummaryResponseForAnotherCurrentRoom() throws {
        let repository = makeRepository(store: InMemoryRoomStore())
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try repository.present(room.roundtable, cursor: 0)

        let otherRoomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000099")!
        let otherSnapshot = try JSONDecoder.roundtable.decode(
            RoundtableSnapshot.self,
            from: Data(
                Fixtures.snapshotJSON.replacingOccurrences(
                    of: Fixtures.roomID.uuidString,
                    with: otherRoomID.uuidString
                ).utf8
            )
        )
        let summary = try JSONDecoder.roundtable.decode(
            RoundSummary.self,
            from: Data(Fixtures.summaryJSON.utf8)
        )

        try repository.apply(
            RoundSummaryResponse(
                roundtable: otherSnapshot,
                summary: summary,
                events: []
            )
        )

        XCTAssertEqual(repository.room?.snapshot?.id, Fixtures.roomID)
        XCTAssertEqual(repository.room?.status, .ready)
        XCTAssertNil(repository.room?.summary)
    }

    func testHidingAndFlaggingAreLocalProjectionChanges() throws {
        let repository = makeRepository(store: InMemoryRoomStore())
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try repository.present(room.roundtable, cursor: 0)
        try repository.apply(
            try EventEnvelope.decode(
                from: Fixtures.envelope(
                    eventType: "message.completed",
                    sequence: 1,
                    payload: "{\"message\": \(Fixtures.messageJSON)}"
                )
            )
        )

        try repository.hideMessage(Fixtures.messageID)
        try repository.flagMessage(Fixtures.messageID)

        XCTAssertEqual(repository.room?.messages.count, 1)
        XCTAssertEqual(repository.room?.hiddenMessageIDs, [Fixtures.messageID])
        XCTAssertEqual(repository.room?.flaggedMessageIDs, [Fixtures.messageID])
    }

    func testDeletingRemoteRoomAlsoRemovesLocalSnapshotAndCursor() async throws {
        let store = InMemoryRoomStore()
        let transport = StubTransport(
            responses: [.init(data: Data(), statusCode: 204)]
        )
        let repository = RoundtableRepository(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            ),
            store: store
        )
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try repository.present(room.roundtable, cursor: 0)

        try await repository.deleteRoundtable(roomID: room.roundtable.id)

        XCTAssertNil(try store.load(roomID: room.roundtable.id))
        XCTAssertNil(repository.room)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.first?.httpMethod, "DELETE")
    }

    func testDeleteSurfacesLocalCleanupFailureForRetry() async throws {
        let store = DeleteFailingRoomStore()
        let repository = RoundtableRepository(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: StubTransport(
                    responses: [.init(data: Data(), statusCode: 204)]
                ),
                guestSessionId: UUID()
            ),
            store: store
        )
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected a joined payload")
        }
        try repository.present(room.roundtable, cursor: 0)

        do {
            try await repository.deleteRoundtable(roomID: room.roundtable.id)
            XCTFail("expected local cleanup failure")
        } catch let error as RoundtableDeletionError {
            guard case .local = error else {
                return XCTFail("expected local failure, got \(error)")
            }
        }
        XCTAssertNotNil(repository.room)
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

@MainActor
private final class DeleteFailingRoomStore: RoundtableRoomStore {
    private var state: StoredRoomState?

    func save(_ state: StoredRoomState) throws {
        self.state = state
    }

    func load(roomID: UUID) throws -> StoredRoomState? {
        state?.snapshot.id == roomID ? state : nil
    }

    func loadMostRecent() throws -> StoredRoomState? {
        state
    }

    func delete(roomID: UUID) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
