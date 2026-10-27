import Foundation

public struct BudgetSnapshot: Codable, Equatable, Sendable {
    public let maxRounds: Int
    public let maxAgentMessages: Int
    public let agentMessagesUsed: Int
    public let maxReportedTokens: Int
    public let reportedTokens: Int
    public let maxDurationSeconds: Int
    public let startedAt: Date?
    public let elapsedSeconds: Int
    public let exhaustedReason: String?
    public let tokenSource: String

    public init(
        maxRounds: Int,
        maxAgentMessages: Int,
        agentMessagesUsed: Int,
        maxReportedTokens: Int,
        reportedTokens: Int,
        maxDurationSeconds: Int,
        startedAt: Date? = nil,
        elapsedSeconds: Int = 0,
        exhaustedReason: String? = nil,
        tokenSource: String = "client_reported"
    ) {
        self.maxRounds = maxRounds
        self.maxAgentMessages = maxAgentMessages
        self.agentMessagesUsed = agentMessagesUsed
        self.maxReportedTokens = maxReportedTokens
        self.reportedTokens = reportedTokens
        self.maxDurationSeconds = maxDurationSeconds
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.exhaustedReason = exhaustedReason
        self.tokenSource = tokenSource
    }
}
