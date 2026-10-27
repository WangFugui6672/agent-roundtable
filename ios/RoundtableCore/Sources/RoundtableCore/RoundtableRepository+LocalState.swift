import Foundation

extension RoundtableRepository {
    public func markVisibleMessage(_ messageID: UUID?) throws {
        guard let room else { return }
        room.setLastVisibleMessage(messageID)
        try persist()
    }

    public func flagMessage(_ messageID: UUID) throws {
        guard let room else { return }
        room.flagMessage(messageID)
        try persist()
    }

    public func hideMessage(_ messageID: UUID) throws {
        guard let room else { return }
        room.hideMessage(messageID)
        try persist()
    }

    public func showMessage(_ messageID: UUID) throws {
        guard let room else { return }
        room.showMessage(messageID)
        try persist()
    }

    public func flagSummary(_ summaryID: UUID) throws {
        guard let room, room.summary?.id == summaryID else { return }
        room.flagSummary(summaryID)
        try persist()
    }

    public func save() throws {
        try persist()
    }

    public func load(roomID: UUID) throws -> StoredRoomState? {
        try store.load(roomID: roomID)
    }
}
