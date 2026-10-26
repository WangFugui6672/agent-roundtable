import Foundation
import RoundtableCore

final class ProviderRunMetrics {
    private let startedAt = Date()
    private var inputTokens: Int?
    private var outputTokens: Int?

    func consume(_ event: ProviderStreamEvent) {
        guard case let .usage(usage) = event else { return }
        if let value = usage.inputTokens {
            inputTokens = (inputTokens ?? 0) + value
        }
        if let value = usage.outputTokens {
            outputTokens = (outputTokens ?? 0) + value
        }
    }

    func report(retryCount: Int) -> ProviderUsageReport {
        ProviderUsageReport(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            latencyMs: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
            retryCount: retryCount
        )
    }
}

final class ProviderTextCollector {
    var text = ""
}

struct ProviderStreamContext {
    let configuration: ProviderConfiguration
    let apiKey: String
    let prompt: [ChatMessage]
    let collector: ProviderTextCollector
    let metrics: ProviderRunMetrics
}

struct TurnFailureContext {
    let turn: ScheduledTurn
    let roundtableID: UUID
    let room: RoundtableRoomModel
}

private struct FailureDescriptor {
    let code: String
    let message: String
    let retryable: Bool
}

struct TurnFailureReport {
    let code: String
    let message: String
    let retryable: Bool
    let partial: String?
    let usage: ProviderUsageReport

    @MainActor
    init(error: Error, partial: String? = nil, usage: ProviderUsageReport) {
        let descriptor = Self.descriptor(for: error)
        code = descriptor.code
        message = descriptor.message
        retryable = descriptor.retryable
        self.partial = partial
        self.usage = usage
    }

    init(
        code: String,
        message: String,
        retryable: Bool,
        partial: String? = nil,
        usage: ProviderUsageReport
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.partial = partial
        self.usage = usage
    }

    @MainActor
    private static func descriptor(for error: Error) -> FailureDescriptor {
        if let provider = error as? ProviderError {
            return FailureDescriptor(
                code: provider.failureCode,
                message: provider.message,
                retryable: provider.retryable
            )
        }
        if error is ProviderValidationError || error is KeychainError {
            return FailureDescriptor(
                code: "provider_not_configured",
                message: AppModel.userMessage(for: error),
                retryable: false
            )
        }
        if let api = error as? APIError {
            return FailureDescriptor(
                code: "client_request_failed",
                message: api.message,
                retryable: api.statusCode >= 500
            )
        }
        return FailureDescriptor(
            code: "provider_error",
            message: AppModel.userMessage(for: error),
            retryable: true
        )
    }
}

extension AppModel {
    func failUnknownParticipant(context: TurnFailureContext) async {
        await failTurn(
            context: context,
            report: TurnFailureReport(
                code: "scheduler_invalid_agent",
                message: "调度器返回了未知参与者。",
                retryable: false,
                usage: ProviderUsageReport(latencyMs: 0)
            )
        )
    }

    func loadAPIKey(
        for configuration: ProviderConfiguration,
        participantID: UUID,
        context: TurnFailureContext
    ) async -> String? {
        do {
            let apiKey = try providerStore.secret(for: configuration.kind) ?? ""
            guard !apiKey.isEmpty else {
                await failTurn(
                    context: context,
                    report: TurnFailureReport(
                        code: "provider_not_configured",
                        message: "API Key 为空，请重新输入。",
                        retryable: false,
                        usage: ProviderUsageReport(latencyMs: 0)
                    )
                )
                return nil
            }
            return apiKey
        } catch {
            await failTurn(
                context: context,
                report: TurnFailureReport(
                    error: error,
                    usage: ProviderUsageReport(latencyMs: 0)
                )
            )
            return nil
        }
    }

    func failTurn(context: TurnFailureContext, report: TurnFailureReport) async {
        turnState = .failed(
            agentID: context.turn.roundtableAgentId,
            message: report.message,
            partial: report.partial
        )
        failureCode = report.code
        failureRetryable = report.retryable
        scheduledTurn = nil

        guard reportedFailureTurnIDs.insert(context.turn.turnId).inserted else { return }
        do {
            let envelope = try await api.reportTurnFailure(
                roundtableID: context.roundtableID,
                submission: TurnFailureSubmission(
                    turnId: context.turn.turnId,
                    roundtableAgentId: context.turn.roundtableAgentId,
                    failureCode: report.code,
                    message: report.message,
                    retryable: report.retryable,
                    partial: report.partial,
                    usage: report.usage
                )
            )
            context.room.apply(envelope)
        } catch {
            turnState = .failed(
                agentID: context.turn.roundtableAgentId,
                message: "\(report.message) 失败状态同步失败：\(Self.userMessage(for: error))",
                partial: report.partial
            )
        }
    }

    func failBeforeTurn(room: RoundtableRoomModel, error: Error) {
        guard let participant = room.participants.first else { return }
        let report = TurnFailureReport(
            error: error,
            usage: ProviderUsageReport(latencyMs: 0)
        )
        turnState = .failed(agentID: participant.id, message: report.message, partial: nil)
        failureCode = report.code
        failureRetryable = report.retryable
    }

    func failBeforeTurn(
        room: RoundtableRoomModel,
        message: String,
        code: String = "provider_not_configured",
        retryable: Bool = false
    ) {
        guard let participant = room.participants.first else { return }
        turnState = .failed(agentID: participant.id, message: message, partial: nil)
        failureCode = code
        failureRetryable = retryable
    }
}
