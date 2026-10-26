import Foundation
import Observation
import RoundtableCore

/// Executes server-scheduled Provider turns for the first round.
extension AppModel {
    // MARK: - First round (Issue #5)

    func runFirstRound() async {
        guard !isFirstRoundRunning, let room else { return }
        guard let roundtableID = room.snapshot?.id else { return }
        guard let configuration = activeConfiguration else {
            failBeforeTurn(
                room: room,
                message: providerIncompleteMessage ?? "尚未配置 Provider，无法调用真实模型。"
            )
            return
        }

        isFirstRoundRunning = true
        turnState = .idle
        defer { isFirstRoundRunning = false }

        while !Task.isCancelled {
            let response: NextTurnResponse
            do {
                response = try await api.nextTurn(roundtableID: roundtableID)
            } catch {
                failBeforeTurn(room: room, message: Self.userMessage(for: error))
                return
            }

            for event in response.events {
                room.apply(event)
            }

            guard let turn = response.turn else {
                scheduledTurn = nil
                turnState = .roundCompleted(round: response.round)
                return
            }

            scheduledTurn = turn
            guard await runScheduledTurn(
                turn,
                configuration: configuration,
                roundtableID: roundtableID,
                room: room
            ) else {
                return
            }
            scheduledTurn = nil
        }
    }

    /// Re-runs the failed turn identity. The next-turn request is idempotent,
    /// so a Provider failure does not create a replacement server turn.
    func retryTurn() async {
        guard case .failed = turnState else { return }
        turnState = .idle
        await runFirstRound()
    }

    func dismissTurnError() {
        switch turnState {
        case .failed, .completed, .passed, .roundCompleted:
            turnState = .idle
        default:
            break
        }
    }

    private func runScheduledTurn(
        _ turn: ScheduledTurn,
        configuration: ProviderConfiguration,
        roundtableID: UUID,
        room: RoundtableRoomModel
    ) async -> Bool {
        guard let participant = room.participants.first(where: {
            $0.id == turn.roundtableAgentId
        }) else {
            turnState = .failed(
                agentID: turn.roundtableAgentId,
                message: "调度器返回了未知参与者。",
                partial: nil
            )
            return false
        }

        let apiKey: String
        do {
            apiKey = try providerStore.secret(for: configuration.kind) ?? ""
        } catch {
            turnState = .failed(
                agentID: participant.id,
                message: Self.userMessage(for: error),
                partial: nil
            )
            return false
        }
        guard !apiKey.isEmpty else {
            turnState = .failed(
                agentID: participant.id,
                message: "API Key 为空，请重新输入。",
                partial: nil
            )
            return false
        }

        let prompt = AgentPrompt.messages(
            topic: room.snapshot?.topic ?? "",
            participant: participant,
            transcript: room.messages
        )
        turnState = .thinking(agentID: participant.id)
        var text = ""

        do {
            for try await delta in chatClient.stream(
                configuration: configuration,
                apiKey: apiKey,
                messages: prompt
            ) {
                text += delta
                turnState = .typing(agentID: participant.id, text: text)
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.emptyReply }

            turnState = .submitting(agentID: participant.id)
            if MessageComposer.isPass(trimmed) {
                let envelope = try await api.passTurn(
                    roundtableID: roundtableID,
                    agentID: participant.id,
                    turnID: turn.turnId
                )
                room.apply(envelope)
                turnState = .passed(agentID: participant.id)
                return true
            }

            let submission = MessageComposer.compose(
                participant: participant,
                text: trimmed,
                turn: turn
            )
            let envelope = try await api.submitMessage(
                roundtableID: roundtableID,
                submission: submission
            )
            room.apply(envelope)
            turnState = .completed(agentID: participant.id)
            return true
        } catch {
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            turnState = .failed(
                agentID: participant.id,
                message: Self.userMessage(for: error),
                partial: partial.isEmpty ? nil : partial
            )
            return false
        }
    }

    private func failBeforeTurn(room: RoundtableRoomModel, message: String) {
        guard let participant = room.participants.first else { return }
        turnState = .failed(agentID: participant.id, message: message, partial: nil)
    }
}
