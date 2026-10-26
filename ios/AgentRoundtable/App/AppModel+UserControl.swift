import Foundation
import RoundtableCore

extension AppModel {
    func sendUserMessage(_ body: String, mentionedAgentIDs: [UUID]) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSendingUserMessage, !isEnding, let room else { return }
        guard let roundtableID = room.snapshot?.id else { return }

        isSendingUserMessage = true
        controlError = nil
        defer { isSendingUserMessage = false }

        do {
            let result = try await repository.sendUserMessage(
                roundtableID: roundtableID,
                body: trimmed,
                mentionedAgentIDs: Array(mentionedAgentIDs.prefix(3))
            )
            try repository.apply(result)
            if room.status == .paused {
                turnState = .paused
            }
        } catch {
            controlError = Self.userMessage(for: error)
        }
    }

    func pauseDiscussion() async {
        _ = await runControl { roundtableID in
            try await self.repository.pauseRoundtable(roundtableID: roundtableID)
        }
    }

    func resumeDiscussion() async {
        let resumed = await runControl { roundtableID in
            try await self.repository.resumeRoundtable(roundtableID: roundtableID)
        }
        if resumed, room?.status == .running {
            turnState = .idle
            startGeneration()
        }
    }

    func endDiscussion() async {
        guard !isChangingDiscussion, let room, let roundtableID = room.snapshot?.id else {
            return
        }
        isChangingDiscussion = true
        isEnding = true
        controlError = nil
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        defer {
            isChangingDiscussion = false
            isEnding = false
        }

        do {
            let result = try await repository.endRoundtable(roundtableID: roundtableID)
            try repository.apply(result)
            scheduledTurn = nil
            turnState = .ended
        } catch {
            controlError = Self.userMessage(for: error)
        }
    }

    private func runControl(
        _ operation: @escaping (UUID) async throws -> RoomCommandResponse
    ) async -> Bool {
        guard !isChangingDiscussion, !isEnding, let room else { return false }
        guard let roundtableID = room.snapshot?.id else { return false }
        isChangingDiscussion = true
        controlError = nil
        defer { isChangingDiscussion = false }

        do {
            let result = try await operation(roundtableID)
            try repository.apply(result)
            if room.status == .paused {
                turnState = .paused
            }
            return true
        } catch {
            controlError = Self.userMessage(for: error)
            return false
        }
    }

}
