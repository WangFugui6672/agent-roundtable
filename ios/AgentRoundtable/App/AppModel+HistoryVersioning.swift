import Foundation
import RoundtableCore

extension AppModel {
    func toggleKeyPoint(_ messageID: UUID) async {
        guard let room,
              let roundtableID = room.snapshot?.id,
              let message = room.messages.first(where: { $0.id == messageID }),
              message.author.type == .agent
        else {
            return
        }
        controlError = nil
        do {
            try await repository.setKeyPoint(
                roundtableID: roundtableID,
                messageID: messageID,
                isKeyPoint: !message.isKeyPoint
            )
        } catch {
            controlError = "关键观点更新失败：\(Self.userMessage(for: error))"
        }
    }

    func regenerateMessage(_ messageID: UUID) async {
        guard !isRegeneratingMessage,
              let room,
              let roundtableID = room.snapshot?.id,
              room.messages.last(where: { $0.author.type == .agent })?.id == messageID
        else {
            return
        }
        isRegeneratingMessage = true
        controlError = nil
        defer { isRegeneratingMessage = false }
        do {
            let response = try await repository.regenerateMessage(
                roundtableID: roundtableID,
                messageID: messageID
            )
            try repository.apply(response.events)
            if response.turn != nil {
                turnState = .idle
                startGeneration()
            }
        } catch {
            controlError = "重新生成失败：\(Self.userMessage(for: error))"
        }
    }

    func rotateGuestSession() async {
        guard !isManagingSession else { return }
        isManagingSession = true
        controlError = nil
        defer { isManagingSession = false }
        do {
            let replacement = try await repository.rotateGuestSession()
            do {
                try guestSessionStore.rotate(to: replacement.id)
            } catch {
                // Keep the live session usable even if Keychain persistence fails.
                controlError = "会话已轮换，但 Keychain 更新失败：\(Self.userMessage(for: error))"
            }
            guestSessionID = replacement.id
            repository.setGuestSession(replacement.id)
            if room != nil {
                repository.connect(guestSessionID: replacement.id)
            }
        } catch {
            controlError = "匿名会话轮换失败：\(Self.userMessage(for: error))"
        }
    }

    func deleteGuestSession() async {
        guard !isManagingSession, let guestSessionID else { return }
        isManagingSession = true
        controlError = nil
        defer { isManagingSession = false }
        do {
            try await repository.deleteGuestSession()
            try? guestSessionStore.clear()
            for state in try repository.loadCachedRooms() {
                try? repository.deleteLocalRoom(roomID: state.snapshot.id)
            }
            self.guestSessionID = nil
            repository.setGuestSession(nil)
            repository.leaveRoom()
            historyEntries = []
            isRoomPresented = false
            resetAfterRoomDeletion()
        } catch {
            repository.setGuestSession(guestSessionID)
            controlError = "删除匿名会话失败：\(Self.userMessage(for: error))"
            await refreshHistory()
        }
    }
}
