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

@Model
final class DeletedRoomRecord {
    @Attribute(.unique) var roomID: UUID
    var deletedAt: Date

    init(roomID: UUID, deletedAt: Date = Date()) {
        self.roomID = roomID
        self.deletedAt = deletedAt
    }
}

@MainActor
public final class SwiftDataRoomStore: RoundtableRoomStore {
    private let context: ModelContext

    public init(storeURL: URL) throws {
        let schema = Schema([StoredRoomRecord.self, DeletedRoomRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func save(_ state: StoredRoomState) throws {
        guard try deletedRecord(roomID: state.snapshot.id) == nil else { return }
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
        guard try deletedRecord(roomID: roomID) == nil else { return nil }
        guard let record = try record(roomID: roomID) else { return nil }
        return try JSONDecoder().decode(StoredRoomState.self, from: record.payload)
    }

    public func loadMostRecent() throws -> StoredRoomState? {
        let deleted = try deletedRoomIDs()
        var descriptor = FetchDescriptor<StoredRoomRecord>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, deleted.count + 1)
        guard let record = try context.fetch(descriptor).first(where: {
            !deleted.contains($0.roomID)
        }) else { return nil }
        return try JSONDecoder().decode(StoredRoomState.self, from: record.payload)
    }

    public func loadAll() throws -> [StoredRoomState] {
        let deleted = try deletedRoomIDs()
        let descriptor = FetchDescriptor<StoredRoomRecord>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .filter { !deleted.contains($0.roomID) }
            .map { try JSONDecoder().decode(StoredRoomState.self, from: $0.payload) }
    }

    public func markDeleted(roomID: UUID) throws {
        guard try deletedRecord(roomID: roomID) == nil else { return }
        context.insert(DeletedRoomRecord(roomID: roomID))
        try context.save()
    }

    public func delete(roomID: UUID) throws {
        try markDeleted(roomID: roomID)
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

    private func deletedRecord(roomID: UUID) throws -> DeletedRoomRecord? {
        var descriptor = FetchDescriptor<DeletedRoomRecord>()
        descriptor.predicate = #Predicate { $0.roomID == roomID }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func deletedRoomIDs() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<DeletedRoomRecord>()).map(\.roomID))
    }
}
