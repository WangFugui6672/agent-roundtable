import Foundation
import Observation
import RoundtableCore

private struct GenerationContext {
    let room: RoundtableRoomModel
    let roundtableID: UUID
    let configuration: ProviderConfiguration
}

private struct TurnSubmissionContext {
    let participant: Participant
    let turn: ScheduledTurn
    let roundtableID: UUID
    let room: RoundtableRoomModel
}

/// Executes server-scheduled Provider turns for the first round.
extension AppModel {
    // MARK: - First round (Issue #5)

    func startGeneration() {
        if activeConfiguration != nil,
           !requestProviderDataConsent(for: .startGeneration) {
            return
        }
        _ = launchGeneration()
    }

    private func launchGeneration() -> Task<Void, Never>? {
        guard !isFirstRoundRunning, generationTask == nil else { return generationTask }
        let id = UUID()
        generationID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFirstRound()
            guard self.generationID == id else { return }
            self.generationTask = nil
            self.generationID = nil
        }
        generationTask = task
        return task
    }

    func runFirstRound() async {
        guard let context = beginFirstRound() else { return }
        let room = context.room
        defer { isFirstRoundRunning = false }

        while !Task.isCancelled {
            guard !stopBeforeNextTurn(room) else { return }
            guard let response = await requestNextTurn(context: context) else {
                return
            }

            do {
                try repository.apply(response.events)
            } catch {
                failBeforeTurn(
                    room: room,
                    message: "本地恢复状态保存失败：\(Self.userMessage(for: error))"
                )
                return
            }

            guard let turn = response.turn else {
                scheduledTurn = nil
                if room.status == .summarizing {
                    turnState = .roundCompleted(round: response.round)
                    await generateSummary()
                } else {
                    turnState = room.status == .paused
                        ? .paused
                        : .roundCompleted(round: response.round)
                }
                return
            }

            scheduledTurn = turn
            guard await runScheduledTurn(
                turn,
                configuration: context.configuration,
                roundtableID: context.roundtableID,
                room: room
            ) else {
                return
            }
            scheduledTurn = nil

            if shouldPauseAfterTurn(room) {
                turnState = .paused
                return
            }
        }
    }

    private func beginFirstRound() -> GenerationContext? {
        guard !isFirstRoundRunning, !isEnding, let room else { return nil }
        guard let roundtableID = room.snapshot?.id else { return nil }
        guard let configuration = activeConfiguration else {
            failBeforeTurn(
                room: room,
                message: providerIncompleteMessage ?? "尚未配置 Provider，无法调用真实模型。"
            )
            return nil
        }
        guard requestProviderDataConsent(for: .startGeneration) else {
            return nil
        }
        isFirstRoundRunning = true
        turnState = .idle
        failureCode = nil
        failureRetryable = false
        return GenerationContext(
            room: room,
            roundtableID: roundtableID,
            configuration: configuration
        )
    }

    private func stopBeforeNextTurn(_ room: RoundtableRoomModel) -> Bool {
        if isEnding {
            return true
        }
        switch room.status {
        case .paused:
            turnState = .paused
            return true
        case .completed:
            turnState = .ended
            return true
        default:
            return false
        }
    }

    private func requestNextTurn(context: GenerationContext) async -> NextTurnResponse? {
        do {
            let response = try await repository.nextTurn(roundtableID: context.roundtableID)
            if let budget = response.budget {
                context.room.updateBudget(budget)
            }
            return response
        } catch {
            guard !Task.isCancelled, !isEnding else { return nil }
            failBeforeTurn(room: context.room, error: error)
            return nil
        }
    }

    private func shouldPauseAfterTurn(_ room: RoundtableRoomModel) -> Bool {
        room.pausePending || room.status == .paused
    }

    /// Continues after a retryable failure. The server either returns the still
    /// pending turn (if failure sync failed) or schedules the next eligible Agent.
    func retryTurn() async {
        guard case .failed = turnState, failureRetryable else { return }
        turnState = .idle
        failureCode = nil
        failureRetryable = false
        await launchGeneration()?.value
    }

    func dismissTurnError() {
        switch turnState {
        case .failed, .completed, .passed, .roundCompleted, .paused, .ended:
            turnState = .idle
            failureCode = nil
            failureRetryable = false
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
        let failureContext = TurnFailureContext(
            turn: turn,
            roundtableID: roundtableID,
            room: room
        )
        guard let participant = room.participants.first(where: {
            $0.id == turn.roundtableAgentId
        }) else {
            await failUnknownParticipant(context: failureContext)
            return false
        }

        guard let apiKey = await loadAPIKey(
            for: configuration,
            participantID: participant.id,
            context: failureContext
        ) else {
            return false
        }

        if turn.round >= 2 {
            return await runSecondRoundTurn(
                turn,
                context: SecondRoundContext(
                    participant: participant,
                    configuration: configuration,
                    apiKey: apiKey,
                    roundtableID: roundtableID,
                    room: room
                )
            )
        }
        return await runFirstRoundTurn(
            turn,
            participant: participant,
            configuration: configuration,
            apiKey: apiKey,
            failureContext: failureContext
        )
    }

    private func runFirstRoundTurn(
        _ turn: ScheduledTurn,
        participant: Participant,
        configuration: ProviderConfiguration,
        apiKey: String,
        failureContext: TurnFailureContext
    ) async -> Bool {
        let room = failureContext.room
        let prompt = AgentPrompt.messages(
            topic: room.snapshot?.topic ?? "",
            participant: participant,
            transcript: room.messages
        )
        let metrics = ProviderRunMetrics()
        let collector = ProviderTextCollector()

        do {
            let text = try await consumeProviderStream(
                participantID: participant.id,
                stream: ProviderStreamContext(
                    configuration: configuration,
                    apiKey: apiKey,
                    conversationID: failureContext.roundtableID,
                    prompt: prompt,
                    collector: collector,
                    metrics: metrics
                ),
                typingText: { $0 }
            )

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.emptyReply }
            let contentAssessment = contentPolicy.evaluate(trimmed)
            if contentAssessment.decision == .block {
                await failTurn(
                    context: failureContext,
                    report: TurnFailureReport(
                        code: "content_policy_blocked",
                        message: contentAssessment.message ?? "本地安全规则已阻止模型输出。",
                        retryable: false,
                        usage: metrics.report(retryCount: 0)
                    )
                )
                return false
            }

            turnState = .submitting(agentID: participant.id)
            turnState = try await submit(
                trimmed,
                context: TurnSubmissionContext(
                    participant: participant,
                    turn: turn,
                    roundtableID: failureContext.roundtableID,
                    room: room
                ),
                usage: metrics.report(retryCount: 0),
                markFlagged: contentAssessment.decision == .flag
            )
            failureCode = nil
            failureRetryable = false
            return true
        } catch {
            if Task.isCancelled || isEnding {
                return false
            }
            let partial = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            await failTurn(
                context: failureContext,
                report: TurnFailureReport(
                    error: error,
                    partial: partial.isEmpty ? nil : partial,
                    usage: metrics.report(retryCount: 0)
                )
            )
            return false
        }
    }

    func consumeProviderStream(
        participantID: UUID,
        stream: ProviderStreamContext,
        typingText: (String) -> String
    ) async throws -> String {
        turnState = .thinking(agentID: participantID)
        for try await event in chatClient.streamEvents(
            configuration: stream.configuration,
            apiKey: stream.apiKey,
            messages: stream.prompt,
            maxTokens: stream.maxTokens,
            conversationID: stream.conversationID
        ) {
            stream.metrics.consume(event)
            if case let .delta(delta) = event {
                stream.collector.text += delta
                turnState = .typing(
                    agentID: participantID,
                    text: typingText(stream.collector.text)
                )
            }
        }
        return stream.collector.text
    }

    private func submit(
        _ trimmed: String,
        context: TurnSubmissionContext,
        usage: ProviderUsageReport,
        markFlagged: Bool
    ) async throws -> TurnState {
        if MessageComposer.isPass(trimmed) {
            let envelope = try await repository.passTurn(
                roundtableID: context.roundtableID,
                agentID: context.participant.id,
                turnID: context.turn.turnId,
                usage: usage
            )
            try repository.apply(envelope)
            return .passed(agentID: context.participant.id)
        }

        var submission = MessageComposer.compose(
            participant: context.participant,
            text: trimmed,
            turn: context.turn
        )
        submission.usage = usage
        let envelope = try await repository.submitMessage(
            roundtableID: context.roundtableID,
            submission: submission
        )
        try repository.apply(envelope)
        if markFlagged, let messageID = envelope.completedMessageID {
            try repository.flagMessage(messageID)
        }
        return .completed(agentID: context.participant.id)
    }
}
