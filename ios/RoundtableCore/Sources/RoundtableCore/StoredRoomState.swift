import Foundation

public struct StoredRoomState: Codable, Equatable, Sendable {
    public let snapshot: RoundtableSnapshot
    public let messages: [Message]
    public let failures: [TurnFailure]
    public let budgetExhaustion: BudgetExhaustion?
    public let summary: RoundSummary?
    public let lastSequence: Int
    public let seenEventIDs: [UUID]
    public let lastVisibleMessageID: UUID?
    public let flaggedMessageIDs: [UUID]
    public let hiddenMessageIDs: [UUID]
    public let reportedMessageIDs: [UUID]
    public let flaggedSummaryIDs: [UUID]
    public let savedAt: Date

    public init(
        snapshot: RoundtableSnapshot,
        messages: [Message],
        failures: [TurnFailure],
        budgetExhaustion: BudgetExhaustion?,
        summary: RoundSummary? = nil,
        lastSequence: Int,
        seenEventIDs: [UUID],
        lastVisibleMessageID: UUID?,
        flaggedMessageIDs: [UUID] = [],
        hiddenMessageIDs: [UUID] = [],
        reportedMessageIDs: [UUID] = [],
        flaggedSummaryIDs: [UUID] = [],
        savedAt: Date
    ) {
        self.snapshot = snapshot
        self.messages = messages
        self.failures = failures
        self.budgetExhaustion = budgetExhaustion
        self.summary = summary
        self.lastSequence = lastSequence
        self.seenEventIDs = seenEventIDs
        self.lastVisibleMessageID = lastVisibleMessageID
        self.flaggedMessageIDs = flaggedMessageIDs
        self.hiddenMessageIDs = hiddenMessageIDs
        self.reportedMessageIDs = reportedMessageIDs
        self.flaggedSummaryIDs = flaggedSummaryIDs
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case messages
        case failures
        case budgetExhaustion
        case summary
        case lastSequence
        case seenEventIDs
        case lastVisibleMessageID
        case flaggedMessageIDs
        case hiddenMessageIDs
        case reportedMessageIDs
        case flaggedSummaryIDs
        case savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(RoundtableSnapshot.self, forKey: .snapshot)
        messages = try container.decode([Message].self, forKey: .messages)
        failures = try container.decode([TurnFailure].self, forKey: .failures)
        budgetExhaustion = try container.decodeIfPresent(
            BudgetExhaustion.self,
            forKey: .budgetExhaustion
        )
        summary = try container.decodeIfPresent(RoundSummary.self, forKey: .summary)
        lastSequence = try container.decode(Int.self, forKey: .lastSequence)
        seenEventIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .seenEventIDs
        ) ?? []
        lastVisibleMessageID = try container.decodeIfPresent(
            UUID.self,
            forKey: .lastVisibleMessageID
        )
        flaggedMessageIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .flaggedMessageIDs
        ) ?? []
        hiddenMessageIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .hiddenMessageIDs
        ) ?? []
        reportedMessageIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .reportedMessageIDs
        ) ?? []
        flaggedSummaryIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .flaggedSummaryIDs
        ) ?? []
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }
}
