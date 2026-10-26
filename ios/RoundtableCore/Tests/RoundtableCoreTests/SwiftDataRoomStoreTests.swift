import Foundation
import SwiftData
import XCTest

@testable import RoundtableCore

@MainActor
final class SwiftDataRoomStoreTests: XCTestCase {
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
        XCTAssertEqual(loaded?.lastSequence, state.lastSequence)
        XCTAssertEqual(loaded?.lastVisibleMessageID, state.lastVisibleMessageID)
        XCTAssertEqual(try reopened.loadMostRecent()?.snapshot.id, state.snapshot.id)

        try reopened.delete(roomID: state.snapshot.id)
        XCTAssertNil(try reopened.load(roomID: state.snapshot.id))

        let afterDelete = try SwiftDataRoomStore(storeURL: storeURL)
        XCTAssertNil(try afterDelete.loadMostRecent())
    }

    private func storedState() throws -> StoredRoomState {
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
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
        model.setLastVisibleMessage(Fixtures.messageID)
        XCTAssertEqual(model.messages.map(\.id), [Fixtures.messageID])
        XCTAssertEqual(model.lastVisibleMessageID, Fixtures.messageID)
        let state = model.storedState(savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(state.lastVisibleMessageID, Fixtures.messageID)
        return state
    }

    private enum TestError: Error {
        case missingJoin
    }
}
