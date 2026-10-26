import Foundation
import Observation
import RoundtableCore

/// One real-provider turn: stream, compose the envelope, submit, report.
extension AppModel {
    // MARK: - Real provider turn (Issue #4)

    func runRealTurn(participant: Participant) async {
        guard !turnState.isBusy, let room else { return }
        guard let roundtableID = room.snapshot?.id else { return }

        guard let configuration = activeConfiguration else {
            turnState = .failed(
                agentID: participant.id,
                message: providerIncompleteMessage ?? "尚未配置 Provider，无法调用真实模型。",
                partial: nil
            )
            return
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
            return
        }
        guard !apiKey.isEmpty else {
            turnState = .failed(
                agentID: participant.id,
                message: "API Key 为空，请重新输入。",
                partial: nil
            )
            return
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
            let submission = MessageComposer.compose(participant: participant, text: trimmed)
            let envelope = try await api.submitMessage(
                roundtableID: roundtableID,
                submission: submission
            )
            room.apply(envelope)
            turnState = .completed(agentID: participant.id)
        } catch {
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            turnState = .failed(
                agentID: participant.id,
                message: Self.userMessage(for: error),
                partial: partial.isEmpty ? nil : partial
            )
        }
    }

    /// Re-runs the failed turn with the same provider; the partial draft is
    /// replaced by the new stream.
    func retryTurn() async {
        guard case let .failed(agentID, _, _) = turnState,
              let participant = room?.participants.first(where: { $0.id == agentID })
        else { return }
        turnState = .idle
        await runRealTurn(participant: participant)
    }

    func dismissTurnError() {
        switch turnState {
        case .failed, .completed:
            turnState = .idle
        default:
            break
        }
    }
}
