import Foundation
import Observation
import RoundtableCore

/// One real-provider turn: stream, compose the envelope, submit, report.
extension AppModel {
    // MARK: - Real provider turn (Issue #4)

    func runRealTurn(participant: Participant) async {
        guard case .idle = turnState, let room else { return }
        guard let roundtableID = room.snapshot?.id else { return }

        guard case let .ready(metadata) = providerStore.availability(for: activeProvider),
              let configuration = providerStore.configuration(for: metadata.kind)
        else {
            turnState = .failed(
                agentID: participant.id,
                message: providerIncompleteMessage ?? "尚未配置 Provider，无法调用真实模型。"
            )
            return
        }

        let apiKey: String
        do {
            apiKey = try providerStore.secret(for: metadata.kind) ?? ""
        } catch {
            turnState = .failed(agentID: participant.id, message: Self.providerMessage(for: error))
            return
        }
        guard !apiKey.isEmpty else {
            turnState = .failed(agentID: participant.id, message: "API Key 为空，请重新输入。")
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
            turnState = .idle
        } catch {
            turnState = .failed(
                agentID: participant.id,
                message: Self.turnErrorMessage(for: error)
            )
        }
    }

    func resetTurn() {
        turnState = .idle
    }

    static func turnErrorMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.message
        }
        return message(for: error)
    }
}
