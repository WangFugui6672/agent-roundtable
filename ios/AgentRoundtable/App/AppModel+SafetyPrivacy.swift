import Foundation
import RoundtableCore

extension EventEnvelope {
    var completedMessageID: UUID? {
        guard case let .messageCompleted(message) = payload else { return nil }
        return message.id
    }
}

extension AppModel {
    @discardableResult
    func validateLocalContent(_ text: String) -> Bool {
        let result = contentPolicy.evaluate(text)
        switch result.decision {
        case .allow:
            contentSafetyNotice = nil
            contentSafetyError = nil
            return true
        case .flag:
            contentSafetyNotice = result.message
            contentSafetyError = nil
            return true
        case .block:
            contentSafetyNotice = nil
            contentSafetyError = result.message
            return false
        }
    }

    func hideMessage(_ messageID: UUID) {
        guard room?.messages.contains(where: { $0.id == messageID }) == true else { return }
        do {
            try repository.hideMessage(messageID)
        } catch {
            controlError = "隐藏消息失败：\(Self.userMessage(for: error))"
        }
    }

    func showMessage(_ messageID: UUID) {
        do {
            try repository.showMessage(messageID)
        } catch {
            controlError = "恢复消息失败：\(Self.userMessage(for: error))"
        }
    }

    func reportMessage(_ messageID: UUID, reason: MessageReportReason) async {
        guard let room,
              let roundtableID = room.snapshot?.id,
              room.messages.contains(where: {
                  $0.id == messageID && $0.author.type == .agent
              })
        else {
            return
        }
        controlError = nil
        do {
            _ = try await repository.reportMessage(
                roundtableID: roundtableID,
                messageID: messageID,
                reason: reason
            )
            contentSafetyNotice = "举报已提交给维护者；这不代表内容已经通过或未通过审核。"
        } catch {
            controlError = "举报失败：\(Self.userMessage(for: error))"
        }
    }

    func deleteCurrentRoom() async {
        guard !isDeletingRoom, let room, let roundtableID = room.snapshot?.id else {
            return
        }
        isDeletingRoom = true
        controlError = nil
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        summaryTask?.cancel()
        summaryTask = nil
        summaryGenerationID = nil
        repository.disconnect(reason: nil)
        defer { isDeletingRoom = false }

        do {
            try await repository.deleteRoundtable(roomID: roundtableID)
            resetAfterRoomDeletion()
        } catch {
            if case RoundtableDeletionError.server = error, let guestSessionID {
                repository.connect(guestSessionID: guestSessionID)
            }
            controlError = Self.userMessage(for: error)
        }
    }
}
