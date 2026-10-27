import Foundation
import RoundtableCore

struct SecondRoundContext {
    let participant: Participant
    let configuration: ProviderConfiguration
    let apiKey: String
    let roundtableID: UUID
    let room: RoundtableRoomModel
}

extension AppModel {
    func runSecondRoundTurn(
        _ turn: ScheduledTurn,
        context: SecondRoundContext
    ) async -> Bool {
        let basePrompt = AgentPrompt.messages(
            topic: context.room.snapshot?.topic ?? "",
            participant: context.participant,
            transcript: context.room.messages,
            roundNumber: turn.round
        )
        let metrics = ProviderRunMetrics()

        for attempt in 0 ..< 2 {
            if let result = await runSecondRoundAttempt(
                turn,
                context: context,
                attempt: attempt,
                basePrompt: basePrompt,
                metrics: metrics
            ) {
                return result
            }
        }
        return false
    }

    private func runSecondRoundAttempt(
        _ turn: ScheduledTurn,
        context: SecondRoundContext,
        attempt: Int,
        basePrompt: [ChatMessage],
        metrics: ProviderRunMetrics
    ) async -> Bool? {
        let prompt = attempt == 0
            ? basePrompt
            : basePrompt + [
                .user(
                    """
                    上一次输出不是合法的互评 JSON。请严格只返回 system 要求的 JSON 对象，
                    必须包含合法 stance、一条候选引用、可选 challenge_target_agent_id 和 confidence。
                    """
                )
            ]
        let collector = ProviderTextCollector()
        do {
            let text = try await consumeProviderStream(
                participantID: context.participant.id,
                stream: ProviderStreamContext(
                    configuration: context.configuration,
                    apiKey: context.apiKey,
                    prompt: prompt,
                    collector: collector,
                    metrics: metrics
                ),
                typingText: { _ in "正在组织引用与立场…" }
            )

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.emptyReply }
            let usage = metrics.report(retryCount: attempt)
            return try await handleSecondRoundText(
                trimmed,
                turn: turn,
                context: context,
                attempt: attempt,
                usage: usage
            )
        } catch {
            if Task.isCancelled || isEnding {
                return false
            }
            let partial = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            await failTurn(
                context: TurnFailureContext(
                    turn: turn,
                    roundtableID: context.roundtableID,
                    room: context.room
                ),
                report: TurnFailureReport(
                    error: error,
                    partial: partial.isEmpty ? nil : partial,
                    usage: metrics.report(retryCount: attempt)
                )
            )
            return false
        }
    }

    private func handleSecondRoundText(
        _ text: String,
        turn: ScheduledTurn,
        context: SecondRoundContext,
        attempt: Int,
        usage: ProviderUsageReport
    ) async throws -> Bool? {
        if MessageComposer.isPass(text) {
            let envelope = try await repository.passTurn(
                roundtableID: context.roundtableID,
                agentID: context.participant.id,
                turnID: turn.turnId,
                usage: usage
            )
            try repository.apply(envelope)
            turnState = .passed(agentID: context.participant.id)
            return true
        }

        let submission: MessageSubmission
        do {
            submission = try StructuredReplyParser.parse(
                text,
                participant: context.participant,
                turn: turn,
                transcript: context.room.messages
            )
        } catch let structuredError as StructuredReplyError {
            if attempt == 0 {
                return nil
            }
            await failTurn(
                context: TurnFailureContext(
                    turn: turn,
                    roundtableID: context.roundtableID,
                    room: context.room
                ),
                report: TurnFailureReport(
                    code: "provider_invalid_response",
                    message: "模型结构化输出无效，已重试一次。"
                        + structuredError.localizedDescription,
                    retryable: true,
                    usage: usage
                )
            )
            return false
        }
        let assessment = contentPolicy.evaluate(
            "\(submission.claim)\n\(submission.body)"
        )
        if assessment.decision == .block {
            await failTurn(
                context: TurnFailureContext(
                    turn: turn,
                    roundtableID: context.roundtableID,
                    room: context.room
                ),
                report: TurnFailureReport(
                    code: "content_policy_blocked",
                    message: assessment.message ?? "本地安全规则已阻止模型输出。",
                    retryable: false,
                    usage: usage
                )
            )
            return false
        }

        turnState = .submitting(agentID: context.participant.id)
        var submissionWithUsage = submission
        submissionWithUsage.usage = usage
        let envelope = try await repository.submitMessage(
            roundtableID: context.roundtableID,
            submission: submissionWithUsage
        )
        try repository.apply(envelope)
        if assessment.decision == .flag, let messageID = envelope.completedMessageID {
            try repository.flagMessage(messageID)
        }
        turnState = .completed(agentID: context.participant.id)
        failureCode = nil
        failureRetryable = false
        return true
    }

}
