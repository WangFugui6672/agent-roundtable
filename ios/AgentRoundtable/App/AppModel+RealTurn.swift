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
            failBeforeTurn(room: context.room, message: Self.userMessage(for: error))
            return nil
        }
    }

    private func shouldPauseAfterTurn(_ room: RoundtableRoomModel) -> Bool {
        room.pausePending || room.status == .paused
    }

    /// Re-runs the failed turn identity. The next-turn request is idempotent,
    /// so a Provider failure does not create a replacement server turn.
    func retryTurn() async {
        guard case .failed = turnState else { return }
        turnState = .idle
        await launchGeneration()?.value
    }

    func dismissTurnError() {
        switch turnState {
        case .failed, .completed, .passed, .roundCompleted, .paused, .ended:
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
            failTurn(agentID: turn.roundtableAgentId, message: "调度器返回了未知参与者。")
            return false
        }

        guard let apiKey = loadAPIKey(for: configuration, participantID: participant.id) else {
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
            turnState = try await submit(
                trimmed,
                participant: participant,
                turn: turn,
                roundtableID: roundtableID,
                room: room
            )
            return true
        } catch {
            if Task.isCancelled || isEnding {
                return false
            }
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            failTurn(
                agentID: participant.id,
                message: Self.userMessage(for: error),
                partial: partial.isEmpty ? nil : partial
            )
            return false
        }
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

        for attempt in 0 ..< 2 {
            if let result = await runSecondRoundAttempt(
                turn,
                context: context,
                attempt: attempt,
                basePrompt: basePrompt
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
        basePrompt: [ChatMessage]
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
        var text = ""
        do {
            turnState = .thinking(agentID: context.participant.id)
            for try await delta in chatClient.stream(
                configuration: context.configuration,
                apiKey: context.apiKey,
                messages: prompt
            ) {
                text += delta
                turnState = .typing(
                    agentID: context.participant.id,
                    text: "正在组织引用与立场…"
                )
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.emptyReply }
            if MessageComposer.isPass(trimmed) {
                let envelope = try await api.passTurn(
                    roundtableID: context.roundtableID,
                    agentID: context.participant.id,
                    turnID: turn.turnId
                )
                context.room.apply(envelope)
                turnState = .passed(agentID: context.participant.id)
                return true
            }

            let submission: MessageSubmission
            do {
                submission = try StructuredReplyParser.parse(
                    trimmed,
                    participant: context.participant,
                    turn: turn,
                    transcript: context.room.messages
                )
            } catch let structuredError as StructuredReplyError {
                if attempt == 0 {
                    return nil
                }
                failTurn(
                    agentID: context.participant.id,
                    message: "模型结构化输出无效，已重试一次。\(structuredError.localizedDescription)"
                )
                return false
            }

            turnState = .submitting(agentID: context.participant.id)
            let envelope = try await api.submitMessage(
                roundtableID: context.roundtableID,
                submission: submission
            )
            context.room.apply(envelope)
            turnState = .completed(agentID: context.participant.id)
            return true
        } catch {
            if Task.isCancelled || isEnding {
                return false
            }
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            failTurn(
                agentID: context.participant.id,
                message: Self.userMessage(for: error),
                partial: partial.isEmpty ? nil : partial
            )
            return false
        }
    }

    private func loadAPIKey(
        for configuration: ProviderConfiguration,
        participantID: UUID
    ) -> String? {
        do {
            let apiKey = try providerStore.secret(for: configuration.kind) ?? ""
            guard !apiKey.isEmpty else {
                failTurn(agentID: participantID, message: "API Key 为空，请重新输入。")
                return nil
            }
            return apiKey
        } catch {
            failTurn(agentID: participantID, message: Self.userMessage(for: error))
            return nil
        }
    }

    private func submit(
        _ trimmed: String,
        participant: Participant,
        turn: ScheduledTurn,
        roundtableID: UUID,
        room: RoundtableRoomModel
    ) async throws -> TurnState {
        if MessageComposer.isPass(trimmed) {
            let envelope = try await api.passTurn(
                roundtableID: roundtableID,
                agentID: participant.id,
                turnID: turn.turnId
            )
            room.apply(envelope)
            return .passed(agentID: participant.id)
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
        return .completed(agentID: participant.id)
    }

    private func failTurn(agentID: UUID, message: String, partial: String? = nil) {
        turnState = .failed(agentID: agentID, message: message, partial: partial)
    }

    private func failBeforeTurn(room: RoundtableRoomModel, message: String) {
        guard let participant = room.participants.first else { return }
        turnState = .failed(agentID: participant.id, message: message, partial: nil)
    }

    // MARK: - User control (Issue #6)

    func sendUserMessage(_ body: String, mentionedAgentIDs: [UUID]) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSendingUserMessage, !isEnding, let room else { return }
        guard let roundtableID = room.snapshot?.id else { return }

        isSendingUserMessage = true
        controlError = nil
        defer { isSendingUserMessage = false }

        do {
            let result = try await api.sendUserMessage(
                roundtableID: roundtableID,
                body: trimmed,
                mentionedAgentIDs: Array(mentionedAgentIDs.prefix(3))
            )
            apply(result, to: room)
            if room.status == .paused {
                turnState = .paused
            }
        } catch {
            controlError = Self.userMessage(for: error)
        }
    }

    func pauseDiscussion() async {
        _ = await runControl { roundtableID in
            try await self.api.pauseRoundtable(roundtableID: roundtableID)
        }
    }

    func resumeDiscussion() async {
        let resumed = await runControl { roundtableID in
            try await self.api.resumeRoundtable(roundtableID: roundtableID)
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
            let result = try await api.endRoundtable(roundtableID: roundtableID)
            apply(result, to: room)
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
            apply(result, to: room)
            if room.status == .paused {
                turnState = .paused
            }
            return true
        } catch {
            controlError = Self.userMessage(for: error)
            return false
        }
    }

    private func apply(_ result: RoomCommandResponse, to room: RoundtableRoomModel) {
        for event in result.events {
            room.apply(event)
        }
        room.update(from: result.roundtable)
    }
}
