import Foundation

// Wire models mirror the JSON described in docs/protocol.md. The decoder
// converts snake_case keys, so `roundtable_agent_id` becomes `roundtableAgentId`.

public struct GuestSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date

    public init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let key: String
    public let name: String
    public let tagline: String
    public let expertise: String
    public let goal: String
    public let defaultStance: String
    public let style: String
    public let bannedBehaviors: [String]
    public let maxReplyChars: Int

    public init(
        id: UUID,
        key: String,
        name: String,
        tagline: String,
        expertise: String,
        goal: String,
        defaultStance: String,
        style: String,
        bannedBehaviors: [String],
        maxReplyChars: Int
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.tagline = tagline
        self.expertise = expertise
        self.goal = goal
        self.defaultStance = defaultStance
        self.style = style
        self.bannedBehaviors = bannedBehaviors
        self.maxReplyChars = maxReplyChars
    }
}

public enum RoundtableStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case ready
    case running
    case paused
    case summarizing
    case completed
    case failed
    case archived
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RoundtableStatus(rawValue: raw) ?? .unknown
    }
}

public enum AgentState: String, Codable, Sendable, CaseIterable {
    case waiting
    case thinking
    case typing
    case passed
    case completed
    case failed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentState(rawValue: raw) ?? .unknown
    }
}

public struct Participant: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let position: Int
    public var state: AgentState
    public let agent: AgentProfile

    public init(id: UUID, position: Int, state: AgentState, agent: AgentProfile) {
        self.id = id
        self.position = position
        self.state = state
        self.agent = agent
    }
}

public struct RoundtableSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let topic: String
    public var status: RoundtableStatus
    public let mode: String
    public let maxRounds: Int
    public var currentRound: Int
    public let lastSequence: Int
    public let provider: ProviderMetadata?
    public let createdAt: Date
    public let updatedAt: Date
    public var participants: [Participant]

    public init(
        id: UUID,
        topic: String,
        status: RoundtableStatus,
        mode: String,
        maxRounds: Int,
        currentRound: Int,
        lastSequence: Int,
        provider: ProviderMetadata? = nil,
        createdAt: Date,
        updatedAt: Date,
        participants: [Participant]
    ) {
        self.id = id
        self.topic = topic
        self.status = status
        self.mode = mode
        self.maxRounds = maxRounds
        self.currentRound = currentRound
        self.lastSequence = lastSequence
        self.provider = provider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.participants = participants
    }
}

public enum MessageType: String, Codable, Sendable, CaseIterable {
    case proposal
    case support
    case challenge
    case supplement
    case question
    case pass
    case summary
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageType(rawValue: raw) ?? .unknown
    }
}

public enum Stance: String, Codable, Sendable, CaseIterable {
    case support
    case challenge
    case supplement
    case question
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Stance(rawValue: raw) ?? .unknown
    }
}

public struct MessageAuthor: Codable, Equatable, Sendable {
    public let roundtableAgentId: UUID
    public let agentKey: String
    public let name: String

    public init(roundtableAgentId: UUID, agentKey: String, name: String) {
        self.roundtableAgentId = roundtableAgentId
        self.agentKey = agentKey
        self.name = name
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let author: MessageAuthor
    public let messageType: MessageType
    public let claim: String
    public let body: String
    public let stance: Stance?
    public let references: [UUID]
    public let confidence: Double
    public let createdAt: Date

    public init(
        id: UUID,
        author: MessageAuthor,
        messageType: MessageType,
        claim: String,
        body: String,
        stance: Stance?,
        references: [UUID],
        confidence: Double,
        createdAt: Date
    ) {
        self.id = id
        self.author = author
        self.messageType = messageType
        self.claim = claim
        self.body = body
        self.stance = stance
        self.references = references
        self.confidence = confidence
        self.createdAt = createdAt
    }
}
