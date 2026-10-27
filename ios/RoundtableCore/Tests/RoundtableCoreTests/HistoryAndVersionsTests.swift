import Foundation
import XCTest

@testable import RoundtableCore

@MainActor
final class HistoryAndVersionsTests: XCTestCase {
    func testRestoreSpecificCachedRoomIncludesMessagesCursorAndVisiblePosition() throws {
        let store = InMemoryRoomStore()
        let first = makeRepository(store: store)
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected joined room")
        }
        try first.present(room.roundtable, cursor: 0)
        let event = try messageEvent(sequence: 1, id: Fixtures.messageID)
        try first.apply(event)
        try first.markVisibleMessage(Fixtures.messageID)

        let restarted = makeRepository(store: store)
        XCTAssertTrue(try restarted.restore(roomID: Fixtures.roomID))

        XCTAssertEqual(restarted.room?.snapshot?.id, Fixtures.roomID)
        XCTAssertEqual(restarted.room?.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(restarted.room?.lastSequence, 1)
        XCTAssertEqual(restarted.room?.lastVisibleMessageID, Fixtures.messageID)
        XCTAssertEqual(try restarted.loadCachedRooms().map(\.snapshot.id), [Fixtures.roomID])
    }

    func testServerDeletionTombstonePreventsRevivalAfterLocalDeleteFailure() async throws {
        let store = TombstoneFailingStore()
        let repository = RoundtableRepository(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: HistoryTransport(
                    responses: [HTTPResponse(data: Data(), statusCode: 204)]
                ),
                guestSessionId: UUID()
            ),
            store: store
        )
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected joined room")
        }
        try repository.present(room.roundtable, cursor: 0)

        do {
            try await repository.deleteRoundtable(roomID: room.roundtable.id)
            XCTFail("expected local delete failure")
        } catch let error as RoundtableDeletionError {
            guard case .local = error else {
                return XCTFail("expected local failure, got \(error)")
            }
        }

        let restarted = RoundtableRepository(
            api: APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!),
            store: store
        )
        XCTAssertFalse(try restarted.restoreRecent())
        XCTAssertNil(restarted.room)
        XCTAssertTrue(store.isMarkedDeleted(room.roundtable.id))
    }

    func testKeyPointMetadataAndVersionChainSurviveProjectionAndPersistence() async throws {
        let store = InMemoryRoomStore()
        let updatedJSON = Fixtures.messageJSON.replacingOccurrences(
            of: "\"message_type\": \"proposal\",",
            with: "\"message_type\": \"proposal\", \"is_key_point\": true,"
        )
        let repository = RoundtableRepository(
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: HistoryTransport(
                    responses: [
                        HTTPResponse(data: Data(updatedJSON.utf8), statusCode: 200)
                    ]
                )
            ),
            store: store
        )
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(room) = joined.payload else {
            return XCTFail("expected joined room")
        }
        try repository.present(room.roundtable, cursor: 0)
        try repository.apply(try messageEvent(sequence: 1, id: Fixtures.messageID))
        try await repository.setKeyPoint(
            roundtableID: Fixtures.roomID,
            messageID: Fixtures.messageID,
            isKeyPoint: true
        )
        let replacementID = UUID()
        let replacement = Message(
            id: replacementID,
            turnId: UUID(),
            roundNumber: 1,
            author: MessageAuthor(
                roundtableAgentId: Fixtures.advocateID,
                agentKey: "advocate",
                name: "方案派"
            ),
            messageType: .proposal,
            claim: "新版本",
            body: "保留旧版本，同时产生新版本。",
            stance: nil,
            references: [],
            supersedesMessageId: Fixtures.messageID,
            createdAt: Date()
        )
        try repository.apply(
            EventEnvelope(
                eventId: UUID(),
                roomId: Fixtures.roomID,
                sequence: 2,
                createdAt: Date(),
                eventType: "message.completed",
                payload: .messageCompleted(replacement)
            )
        )

        let old = try XCTUnwrap(repository.room?.messages.first { $0.id == Fixtures.messageID })
        XCTAssertTrue(old.isKeyPoint)
        XCTAssertEqual(old.supersededByMessageId, replacementID)
        XCTAssertEqual(repository.room?.messages.count, 2)

        let restarted = makeRepository(store: store)
        XCTAssertTrue(try restarted.restoreRecent())
        let restoredOld = restarted.room?.messages.first {
            $0.id == Fixtures.messageID
        }
        XCTAssertTrue(restoredOld?.isKeyPoint == true)
        XCTAssertEqual(
            restarted.room?.messages.first { $0.id == Fixtures.messageID }?
                .supersededByMessageId,
            replacementID
        )
    }

    func testSummaryCandidatesPrioritizeKeyPointsAndExcludeSupersededVersions() {
        let ordinary = message(id: UUID(), claim: "普通观点", createdAt: Date(timeIntervalSince1970: 1))
        let keyPoint = message(
            id: UUID(),
            claim: "关键观点",
            isKeyPoint: true,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let superseded = message(
            id: UUID(),
            claim: "旧版本",
            supersededByMessageId: UUID(),
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let candidates = StructuredSummaryParser.eligibleMessages(
            from: [ordinary, keyPoint, superseded]
        )

        XCTAssertEqual(candidates.map(\.id), [keyPoint.id, ordinary.id])
    }

    private func messageEvent(sequence: Int, id: UUID) throws -> EventEnvelope {
        let messageJSON = Fixtures.messageJSON.replacingOccurrences(
            of: Fixtures.messageID.uuidString,
            with: id.uuidString
        )
        return try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "message.completed",
                sequence: sequence,
                payload: "{\"message\": \(messageJSON)}"
            )
        )
    }

    private func message(
        id: UUID,
        claim: String,
        isKeyPoint: Bool = false,
        supersededByMessageId: UUID? = nil,
        createdAt: Date
    ) -> Message {
        Message(
            id: id,
            roundNumber: 1,
            author: MessageAuthor(
                roundtableAgentId: UUID(),
                agentKey: "advocate",
                name: "方案派"
            ),
            messageType: .proposal,
            claim: claim,
            body: claim,
            stance: nil,
            references: [],
            isKeyPoint: isKeyPoint,
            supersededByMessageId: supersededByMessageId,
            createdAt: createdAt
        )
    }

    private func makeRepository(store: InMemoryRoomStore) -> RoundtableRepository {
        RoundtableRepository(
            api: APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!),
            store: store
        )
    }
}

private actor HistoryTransport: HTTPTransport {
    private var responses: [HTTPResponse]

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        responses.removeFirst()
    }
}

@MainActor
private final class TombstoneFailingStore: RoundtableRoomStore {
    private var state: StoredRoomState?
    private var deleted: Set<UUID> = []

    func save(_ state: StoredRoomState) throws {
        self.state = state
    }

    func load(roomID: UUID) throws -> StoredRoomState? {
        guard !deleted.contains(roomID), state?.snapshot.id == roomID else { return nil }
        return state
    }

    func loadMostRecent() throws -> StoredRoomState? {
        guard let state, !deleted.contains(state.snapshot.id) else { return nil }
        return state
    }

    func loadAll() throws -> [StoredRoomState] {
        try loadMostRecent().map { [$0] } ?? []
    }

    func markDeleted(roomID: UUID) throws {
        deleted.insert(roomID)
    }

    func delete(roomID: UUID) throws {
        throw CocoaError(.fileWriteUnknown)
    }

    func isMarkedDeleted(_ roomID: UUID) -> Bool {
        deleted.contains(roomID)
    }
}
