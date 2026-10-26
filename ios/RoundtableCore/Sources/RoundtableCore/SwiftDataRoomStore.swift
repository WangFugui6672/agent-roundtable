import Foundation
import SwiftData

@Model
final class StoredRoomRecord {
    @Attribute(.unique) var roomID: UUID
    var payload: Data
    var savedAt: Date

    init(roomID: UUID, payload: Data, savedAt: Date) {
        self.roomID = roomID
        self.payload = payload
        self.savedAt = savedAt
    }
}

@MainActor
public final class SwiftDataRoomStore: RoundtableRoomStore {
    private let context: ModelContext

    public init(storeURL: URL) throws {
        let schema = Schema([StoredRoomRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func save(_ state: StoredRoomState) throws {
        let payload = try JSONEncoder().encode(state)
        if let record = try record(roomID: state.snapshot.id) {
            record.payload = payload
            record.savedAt = state.savedAt
        } else {
            context.insert(
                StoredRoomRecord(
                    roomID: state.snapshot.id,
                    payload: payload,
                    savedAt: state.savedAt
                )
            )
        }
        try context.save()
    }

    public func load(roomID: UUID) throws -> StoredRoomState? {
        guard let record = try record(roomID: roomID) else { return nil }
        return try JSONDecoder().decode(StoredRoomState.self, from: record.payload)
    }

    public func loadMostRecent() throws -> StoredRoomState? {
        var descriptor = FetchDescriptor<StoredRoomRecord>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return try JSONDecoder().decode(StoredRoomState.self, from: record.payload)
    }

    public func delete(roomID: UUID) throws {
        guard let record = try record(roomID: roomID) else { return }
        context.delete(record)
        try context.save()
    }

    private func record(roomID: UUID) throws -> StoredRoomRecord? {
        var descriptor = FetchDescriptor<StoredRoomRecord>()
        descriptor.predicate = #Predicate { $0.roomID == roomID }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
