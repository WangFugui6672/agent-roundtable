import Foundation
import Observation
import RoundtableCore

private struct GenerationContext {
    let room: RoundtableRoomModel
    let roundtableID: UUID
    let configuration: ProviderConfiguration
}

private struct SecondRoundContext {
    let participant: Participant
    let configuration: ProviderConfiguration
    let apiKey: String
    let roundtableID: UUID
    let room: RoundtableRoomModel
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
            return try await api.nextTurn(roundtableID: context.roundtableID)
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

        let prompt = AgentPrompt.messages(
            topic: room.snapshot?.topic ?? "",
            participant: participant,
            transcript: room.messages
        )
        let metrics = ProviderRunMetrics()
        let collector = ProviderTextCollector()

        do {
            let text = try await collectFirstRoundText(
                participantID: participant.id,
                stream: ProviderStreamContext(
                    configuration: configuration,
                    apiKey: apiKey,
                    prompt: prompt,
                    collector: collector,
                    metrics: metrics
                )
            )

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.emptyReply }

            turnState = .submitting(agentID: participant.id)
            turnState = try await submit(
                trimmed,
                context: TurnSubmissionContext(
                    participant: participant,
                    turn: turn,
                    roundtableID: roundtableID,
                    room: room
                ),
                usage: metrics.report(retryCount: 0)
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

    private func collectFirstRoundText(
        participantID: UUID,
        stream: ProviderStreamContext
    ) async throws -> String {
        turnState = .thinking(agentID: participantID)
        for try await event in chatClient.streamEvents(
            configuration: stream.configuration,
            apiKey: stream.apiKey,
            messages: stream.prompt
        ) {
            stream.metrics.consume(event)
            if case let .delta(delta) = event {
                stream.collector.text += delta
                turnState = .typing(agentID: participantID, text: stream.collector.text)
            }
        }
        return stream.collector.text
    }

    private func runSecondRoundTurn(
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
            let text = try await collectSecondRoundText(
                context: context,
                stream: ProviderStreamContext(
                    configuration: context.configuration,
                    apiKey: context.apiKey,
                    prompt: prompt,
                    collector: collector,
                    metrics: metrics
                )
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
            let envelope = try await api.passTurn(
                roundtableID: context.roundtableID,
                agentID: context.participant.id,
                turnID: turn.turnId,
                usage: usage
            )
            context.room.apply(envelope)
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
                    message:
                        "模型结构化输出无效，已重试一次。"
                        + structuredError.localizedDescription,
                    retryable: true,
                    usage: usage
                )
            )
            return false
        }

        turnState = .submitting(agentID: context.participant.id)
        var submissionWithUsage = submission
        submissionWithUsage.usage = usage
        let envelope = try await api.submitMessage(
            roundtableID: context.roundtableID,
            submission: submissionWithUsage
        )
        context.room.apply(envelope)
        turnState = .completed(agentID: context.participant.id)
        failureCode = nil
        failureRetryable = false
        return true
    }

    private func collectSecondRoundText(
        context: SecondRoundContext,
        stream: ProviderStreamContext
    ) async throws -> String {
        turnState = .thinking(agentID: context.participant.id)
        for try await event in chatClient.streamEvents(
            configuration: stream.configuration,
            apiKey: stream.apiKey,
            messages: stream.prompt
        ) {
            stream.metrics.consume(event)
            if case let .delta(delta) = event {
                stream.collector.text += delta
                turnState = .typing(
                    agentID: context.participant.id,
                    text: "正在组织引用与立场…"
                )
            }
        }
        return stream.collector.text
    }

    private func submit(
        _ trimmed: String,
        context: TurnSubmissionContext,
        usage: ProviderUsageReport
    ) async throws -> TurnState {
        if MessageComposer.isPass(trimmed) {
            let envelope = try await api.passTurn(
                roundtableID: context.roundtableID,
                agentID: context.participant.id,
                turnID: context.turn.turnId,
                usage: usage
            )
            context.room.apply(envelope)
            return .passed(agentID: context.participant.id)
        }

        var submission = MessageComposer.compose(
            participant: context.participant,
            text: trimmed,
            turn: context.turn
        )
        submission.usage = usage
        let envelope = try await api.submitMessage(
            roundtableID: context.roundtableID,
            submission: submission
        )
        context.room.apply(envelope)
        return .completed(agentID: context.participant.id)
    }
}
