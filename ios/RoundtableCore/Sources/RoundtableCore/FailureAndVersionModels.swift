import Foundation

public struct TurnFailureSubmission: Codable, Equatable, Sendable {
    public let turnId: UUID
    public let roundtableAgentId: UUID
    public let failureCode: String
    public let message: String
    public let retryable: Bool
    public let partial: String?
    public let usage: ProviderUsageReport?

    public init(
        turnId: UUID,
        roundtableAgentId: UUID,
        failureCode: String,
        message: String,
        retryable: Bool,
        partial: String? = nil,
        usage: ProviderUsageReport? = nil
    ) {
        self.turnId = turnId
        self.roundtableAgentId = roundtableAgentId
        self.failureCode = failureCode
        self.message = message
        self.retryable = retryable
        self.partial = partial
        self.usage = usage
    }
}

public struct TurnFailure: Codable, Equatable, Sendable, Identifiable {
    public let turnId: UUID
    public let round: Int
    public let agentId: UUID
    public let agentName: String
    public let failureCode: String
    public let message: String
    public let retryable: Bool
    public let partial: String?

    public var id: UUID { turnId }

    public init(
        turnId: UUID,
        round: Int,
        agentId: UUID,
        agentName: String,
        failureCode: String,
        message: String,
        retryable: Bool,
        partial: String? = nil
    ) {
        self.turnId = turnId
        self.round = round
        self.agentId = agentId
        self.agentName = agentName
        self.failureCode = failureCode
        self.message = message
        self.retryable = retryable
        self.partial = partial
    }
}

public enum BudgetExhaustionReason: String, Codable, Sendable {
    case duration
    case agentMessages = "agent_messages"
    case reportedTokens = "reported_tokens"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BudgetExhaustionReason(rawValue: raw) ?? .unknown
    }
}

public struct BudgetExhaustion: Codable, Equatable, Sendable {
    public let reason: BudgetExhaustionReason
    public let message: String
    public let round: Int

    public init(reason: BudgetExhaustionReason, message: String, round: Int) {
        self.reason = reason
        self.message = message
        self.round = round
    }
}

public struct RegenerationResponse: Decodable, Equatable, Sendable {
    public let round: Int
    public let turn: ScheduledTurn?
    public let replacementMessageId: UUID?
    public let events: [EventEnvelope]

    public init(
        round: Int,
        turn: ScheduledTurn?,
        replacementMessageId: UUID?,
        events: [EventEnvelope]
    ) {
        self.round = round
        self.turn = turn
        self.replacementMessageId = replacementMessageId
        self.events = events
    }
}
