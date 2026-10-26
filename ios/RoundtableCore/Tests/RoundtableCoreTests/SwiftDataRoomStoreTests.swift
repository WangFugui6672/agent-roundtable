import Foundation
import SwiftData
import XCTest

@testable import RoundtableCore

@MainActor
final class SwiftDataRoomStoreTests: XCTestCase {
    func testPersistedPayloadContainsNoSecretsOrPrompt() throws {
        let state = try storedState()
        XCTAssertNotNil(state.snapshot.provider)

        let data = try JSONEncoder().encode(state)
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = collectKeys(in: object)

        XCTAssertTrue(keys.contains("provider"))
        XCTAssertFalse(keys.contains("api_key"))
        XCTAssertFalse(keys.contains("apiKey"))
        XCTAssertFalse(keys.contains("authorization"))
        XCTAssertFalse(keys.contains("Authorization"))
        XCTAssertFalse(keys.contains("prompt"))
    }

    func testPersistsLoadsDeletesAndReopensFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("rooms.store")
        let state = try storedState()
        XCTAssertEqual(state.lastVisibleMessageID, Fixtures.messageID)

        do {
            let store = try SwiftDataRoomStore(storeURL: storeURL)
            try store.save(state)
        }

        let reopened = try SwiftDataRoomStore(storeURL: storeURL)
        let loaded = try reopened.load(roomID: state.snapshot.id)
        XCTAssertEqual(loaded?.snapshot.id, state.snapshot.id)
        XCTAssertEqual(loaded?.messages, state.messages)
        XCTAssertEqual(loaded?.summary, state.summary)
        XCTAssertEqual(loaded?.lastSequence, state.lastSequence)
        XCTAssertEqual(loaded?.lastVisibleMessageID, state.lastVisibleMessageID)
        XCTAssertEqual(try reopened.loadMostRecent()?.snapshot.id, state.snapshot.id)

        try reopened.delete(roomID: state.snapshot.id)
        XCTAssertNil(try reopened.load(roomID: state.snapshot.id))

        let afterDelete = try SwiftDataRoomStore(storeURL: storeURL)
        XCTAssertNil(try afterDelete.loadMostRecent())
    }

    private func storedState() throws -> StoredRoomState {
        let joined = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "room.joined",
                sequence: 0,
                payload: """
                {
                  "roundtable": \(Fixtures.providerSnapshotJSON),
                  "messages": [],
                  "failures": []
                }
                """
            )
        )
        guard case let .joined(joinedRoom) = joined.payload else {
            throw TestError.missingJoin
        }
        let model = RoundtableRoomModel()
        model.seed(joinedRoom.roundtable, cursor: 0)
        model.apply(
            try EventEnvelope.decode(
                from: Fixtures.envelope(
                    eventType: "message.completed",
                    sequence: 1,
                    payload: "{\"message\": \(Fixtures.messageJSON)}"
                )
            )
        )
        model.apply(
            try EventEnvelope.decode(
                from: Fixtures.envelope(
                    eventType: "summary.completed",
                    sequence: 2,
                    payload: "{\"summary\": \(Fixtures.summaryJSON)}",
                    eventID: UUID()
                )
            )
        )
        model.setLastVisibleMessage(Fixtures.messageID)
        XCTAssertEqual(model.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(model.summary?.id, Fixtures.summaryID)
        XCTAssertEqual(model.lastVisibleMessageID, Fixtures.messageID)
        let state = model.storedState(savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(state.lastVisibleMessageID, Fixtures.messageID)
        return state
    }

    private func collectKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { keys, entry in
                keys.formUnion(collectKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { keys, item in
                keys.formUnion(collectKeys(in: item))
            }
        }
        return []
    }

    private enum TestError: Error {
        case missingJoin
    }
}
