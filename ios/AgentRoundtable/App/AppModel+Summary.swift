import Foundation
import RoundtableCore

enum SummaryGenerationState: Equatable {
    case idle
    case generating
    case completed(version: Int)
    case paused
    case failed(String)

    var isBusy: Bool {
        self == .generating
    }
}

extension AppModel {
    func startSummaryGenerationIfNeeded() {
        guard room?.status == .summarizing,
              room?.summary == nil,
              summaryState != .generating,
              summaryTask == nil
        else {
            return
        }
        if activeConfiguration != nil,
           !requestProviderDataConsent(for: .generateSummary) {
            return
        }
        launchSummaryGeneration()
    }

    func regenerateSummary() {
        guard room?.status == .completed,
              room?.summary != nil,
              summaryState != .generating,
              summaryTask == nil
        else {
            return
        }
        if activeConfiguration != nil,
           !requestProviderDataConsent(for: .generateSummary) {
            return
        }
        launchSummaryGeneration()
    }

    func createFollowUp(topic: String) async {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let room,
              let parentID = room.snapshot?.id,
              room.status == .completed,
              room.summary != nil,
              !trimmed.isEmpty,
              !isCreatingFollowUp
        else {
            return
        }

        isCreatingFollowUp = true
        summaryError = nil
        defer { isCreatingFollowUp = false }
        do {
            let snapshot = try await repository.createFollowUp(
                parentRoundtableID: parentID,
                topic: trimmed
            )
            try repository.present(snapshot)
            if let guestSessionID {
                repository.connect(guestSessionID: guestSessionID)
            }
            generationTask?.cancel()
            generationTask = nil
            generationID = nil
            summaryTask?.cancel()
            summaryTask = nil
            summaryGenerationID = nil
            turnState = .idle
            summaryState = .idle
            scheduledTurn = nil
            failureCode = nil
            failureRetryable = false
            reportedFailureTurnIDs.removeAll()
        } catch {
            summaryError = Self.userMessage(for: error)
        }
    }

    private func launchSummaryGeneration() {
        let id = UUID()
        summaryGenerationID = id
        summaryState = .generating
        summaryTask = Task { [weak self] in
            guard let self else { return }
            await self.generateSummary()
            guard self.summaryGenerationID == id else { return }
            self.summaryTask = nil
            self.summaryGenerationID = nil
        }
    }

    func generateSummary() async {
        guard let room, let roundtableID = room.snapshot?.id else { return }
        if activeConfiguration != nil, !hasProviderDataConsent {
            guard requestProviderDataConsent(for: .generateSummary) else { return }
        }
        summaryState = .generating
        summaryError = nil
        summaryNeedsLocalFlag = false

        let draft = await summaryDraft(room: room)
        guard !Task.isCancelled else {
            summaryState = .paused
            return
        }

        do {
            let response = try await repository.submitSummary(
                roundtableID: roundtableID,
                submission: draft.submission(
                    expectedVersion: room.summary?.version ?? 0
                )
            )
            guard !Task.isCancelled,
                  self.room?.snapshot?.id == roundtableID
            else {
                return
            }
            try repository.apply(response)
            if summaryNeedsLocalFlag {
                try repository.flagSummary(response.summary.id)
            }
            summaryState = .completed(version: response.summary.version)
        } catch {
            guard !Task.isCancelled else {
                summaryState = .paused
                return
            }
            let message = "结论保存失败：\(Self.userMessage(for: error))"
            summaryError = message
            summaryState = .failed(message)
        }
    }

    private func summaryDraft(room: RoundtableRoomModel) async -> SummaryDraft {
        let transcript = room.messages
        guard let configuration = activeConfiguration,
              hasProviderDataConsent,
              let apiKey = try? providerStore.secret(for: configuration.kind),
              !apiKey.isEmpty
        else {
            return RuleBasedSummary.make(transcript: transcript)
        }

        let basePrompt = SummaryPrompt.messages(
            topic: room.snapshot?.topic ?? "",
            transcript: transcript,
            followUpContext: room.snapshot?.followUpContext
        )
        for attempt in 0 ..< 2 {
            do {
                let prompt = attempt == 0
                    ? basePrompt
                    : basePrompt + [
                        .user(
                            """
                            上一次输出未通过严格 schema 校验。请只返回包含
                            consensus、dissent、recommendations、unresolved 的 JSON，
                            reference_indexes 必须来自给定候选观点。
                            """
                        )
                    ]
                var text = ""
                for try await delta in chatClient.stream(
                    configuration: configuration,
                    apiKey: apiKey,
                    messages: prompt,
                    maxTokens: 1_200
                ) {
                    guard !Task.isCancelled else { throw CancellationError() }
                    text += delta
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw ProviderError.emptyReply }
                let draft = try StructuredSummaryParser.parse(
                    trimmed,
                    transcript: transcript
                )
                let summaryText = [
                    draft.consensus,
                    draft.dissent,
                    draft.recommendations,
                    draft.unresolved
                ]
                .flatMap { $0 }
                .map(\.text)
                .joined(separator: "\n")
                let assessment = contentPolicy.evaluate(summaryText)
                if assessment.decision == .block {
                    summaryNeedsLocalFlag = true
                    return RuleBasedSummary.make(transcript: transcript)
                }
                summaryNeedsLocalFlag = assessment.decision == .flag
                return draft
            } catch is StructuredSummaryError {
                if attempt == 0 {
                    continue
                }
                return RuleBasedSummary.make(transcript: transcript)
            } catch is CancellationError {
                return RuleBasedSummary.make(transcript: transcript)
            } catch {
                return RuleBasedSummary.make(transcript: transcript)
            }
        }
        return RuleBasedSummary.make(transcript: transcript)
    }
}
