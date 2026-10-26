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

public struct ScheduledTurn: Codable, Equatable, Sendable {
    public let turnId: UUID
    public let round: Int
    public let roundtableAgentId: UUID
    public let position: Int
    public let agentKey: String
    public let agentName: String

    public init(
        turnId: UUID,
        round: Int,
        roundtableAgentId: UUID,
        position: Int,
        agentKey: String,
        agentName: String
    ) {
        self.turnId = turnId
        self.round = round
        self.roundtableAgentId = roundtableAgentId
        self.position = position
        self.agentKey = agentKey
        self.agentName = agentName
    }
}

public struct NextTurnResponse: Decodable, Equatable, Sendable {
    public let round: Int
    public let turn: ScheduledTurn?
    public let events: [EventEnvelope]

    public init(round: Int, turn: ScheduledTurn?, events: [EventEnvelope]) {
        self.round = round
        self.turn = turn
        self.events = events
    }
}

public struct RoomCommandResponse: Decodable, Equatable, Sendable {
    public let roundtable: RoundtableSnapshot
    public let events: [EventEnvelope]

    public init(roundtable: RoundtableSnapshot, events: [EventEnvelope]) {
        self.roundtable = roundtable
        self.events = events
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
    public let pausePending: Bool?
    public let activeTurn: ScheduledTurn?
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
        pausePending: Bool? = nil,
        activeTurn: ScheduledTurn? = nil,
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
        self.pausePending = pausePending
        self.activeTurn = activeTurn
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
    case userMessage = "user_message"
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

public enum MessageAuthorType: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageAuthorType(rawValue: raw) ?? .unknown
    }
}

public struct MessageAuthor: Codable, Equatable, Sendable {
    public let type: MessageAuthorType
    public let roundtableAgentId: UUID?
    public let agentKey: String?
    public let name: String

    public init(
        type: MessageAuthorType,
        roundtableAgentId: UUID? = nil,
        agentKey: String? = nil,
        name: String
    ) {
        self.type = type
        self.roundtableAgentId = roundtableAgentId
        self.agentKey = agentKey
        self.name = name
    }

    public init(roundtableAgentId: UUID, agentKey: String, name: String) {
        self.init(
            type: .agent,
            roundtableAgentId: roundtableAgentId,
            agentKey: agentKey,
            name: name
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case roundtableAgentId
        case agentKey
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roundtableAgentId = try container.decodeIfPresent(UUID.self, forKey: .roundtableAgentId)
        agentKey = try container.decodeIfPresent(String.self, forKey: .agentKey)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(MessageAuthorType.self, forKey: .type)
            ?? (roundtableAgentId == nil ? .unknown : .agent)
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let turnId: UUID?
    public let roundNumber: Int
    public let author: MessageAuthor
    public let messageType: MessageType
    public let claim: String?
    public let body: String
    public let stance: Stance?
    public let references: [UUID]
    public let confidence: Double?
    public let mentionedAgentIds: [UUID]
    public let createdAt: Date

    public init(
        id: UUID,
        turnId: UUID? = nil,
        roundNumber: Int = 0,
        author: MessageAuthor,
        messageType: MessageType,
        claim: String? = nil,
        body: String,
        stance: Stance?,
        references: [UUID],
        confidence: Double? = nil,
        mentionedAgentIds: [UUID] = [],
        createdAt: Date
    ) {
        self.id = id
        self.turnId = turnId
        self.roundNumber = roundNumber
        self.author = author
        self.messageType = messageType
        self.claim = claim
        self.body = body
        self.stance = stance
        self.references = references
        self.confidence = confidence
        self.mentionedAgentIds = mentionedAgentIds
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnId
        case roundNumber
        case author
        case messageType
        case claim
        case body
        case stance
        case references
        case confidence
        case mentionedAgentIds
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        turnId = try container.decodeIfPresent(UUID.self, forKey: .turnId)
        roundNumber = try container.decodeIfPresent(Int.self, forKey: .roundNumber) ?? 0
        author = try container.decode(MessageAuthor.self, forKey: .author)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        claim = try container.decodeIfPresent(String.self, forKey: .claim)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        stance = try container.decodeIfPresent(Stance.self, forKey: .stance)
        references = try container.decodeIfPresent([UUID].self, forKey: .references) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        mentionedAgentIds =
            try container.decodeIfPresent([UUID].self, forKey: .mentionedAgentIds) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
