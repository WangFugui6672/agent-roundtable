import Foundation

public struct SummaryItem: Codable, Equatable, Sendable {
    public let text: String
    public let referenceMessageIds: [UUID]

    public init(text: String, referenceMessageIds: [UUID]) {
        self.text = text
        self.referenceMessageIds = referenceMessageIds
    }
}

public struct RoundSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let version: Int
    public let degraded: Bool
    public let consensus: [SummaryItem]
    public let dissent: [SummaryItem]
    public let recommendations: [SummaryItem]
    public let unresolved: [SummaryItem]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        version: Int,
        degraded: Bool,
        consensus: [SummaryItem],
        dissent: [SummaryItem],
        recommendations: [SummaryItem],
        unresolved: [SummaryItem],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.version = version
        self.degraded = degraded
        self.consensus = consensus
        self.dissent = dissent
        self.recommendations = recommendations
        self.unresolved = unresolved
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasContent: Bool {
        !consensus.isEmpty
            || !dissent.isEmpty
            || !recommendations.isEmpty
            || !unresolved.isEmpty
    }
}

public struct RoundSummarySubmission: Codable, Equatable, Sendable {
    public let expectedVersion: Int
    public let degraded: Bool
    public let consensus: [SummaryItem]
    public let dissent: [SummaryItem]
    public let recommendations: [SummaryItem]
    public let unresolved: [SummaryItem]

    public init(
        expectedVersion: Int,
        degraded: Bool,
        consensus: [SummaryItem],
        dissent: [SummaryItem],
        recommendations: [SummaryItem],
        unresolved: [SummaryItem]
    ) {
        self.expectedVersion = expectedVersion
        self.degraded = degraded
        self.consensus = consensus
        self.dissent = dissent
        self.recommendations = recommendations
        self.unresolved = unresolved
    }
}

public struct RoundSummaryResponse: Decodable, Equatable, Sendable {
    public let roundtable: RoundtableSnapshot
    public let summary: RoundSummary
    public let events: [EventEnvelope]

    public init(
        roundtable: RoundtableSnapshot,
        summary: RoundSummary,
        events: [EventEnvelope]
    ) {
        self.roundtable = roundtable
        self.summary = summary
        self.events = events
    }
}

public struct FollowUpContext: Codable, Equatable, Sendable {
    public let parentTopic: String
    public let summary: RoundSummary

    public init(parentTopic: String, summary: RoundSummary) {
        self.parentTopic = parentTopic
        self.summary = summary
    }
}
