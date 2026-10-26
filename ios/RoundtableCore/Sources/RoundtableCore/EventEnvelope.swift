import Foundation

// MARK: - Payloads

public struct JoinedRoom: Codable, Equatable, Sendable {
    public let roundtable: RoundtableSnapshot
    public let messages: [Message]

    public init(roundtable: RoundtableSnapshot, messages: [Message]) {
        self.roundtable = roundtable
        self.messages = messages
    }
}

public struct RoundStarted: Codable, Equatable, Sendable {
    public let round: Int
    public let maxRounds: Int?
    public let topic: String?

    public init(round: Int, maxRounds: Int?, topic: String?) {
        self.round = round
        self.maxRounds = maxRounds
        self.topic = topic
    }
}

public struct AgentActivity: Codable, Equatable, Sendable {
    public let agentId: UUID
    public let agentName: String?
    public let turnId: UUID?
    public let round: Int?

    public init(
        agentId: UUID,
        agentName: String?,
        turnId: UUID? = nil,
        round: Int? = nil
    ) {
        self.agentId = agentId
        self.agentName = agentName
        self.turnId = turnId
        self.round = round
    }
}

struct MessageCompletedPayload: Codable, Equatable, Sendable {
    let message: Message
}

public struct RoundCompleted: Codable, Equatable, Sendable {
    public let round: Int

    public init(round: Int) {
        self.round = round
    }
}

public struct RoomPausePending: Codable, Equatable, Sendable {
    public let turnId: UUID

    public init(turnId: UUID) {
        self.turnId = turnId
    }
}

public struct RoomStateChanged: Codable, Equatable, Sendable {
    public let status: RoundtableStatus
    public let cancelledTurnId: UUID?
    public let cancelledAgentId: UUID?

    public init(
        status: RoundtableStatus,
        cancelledTurnId: UUID? = nil,
        cancelledAgentId: UUID? = nil
    ) {
        self.status = status
        self.cancelledTurnId = cancelledTurnId
        self.cancelledAgentId = cancelledAgentId
    }
}

public enum EventPayload: Equatable, Sendable {
    case joined(JoinedRoom)
    case roundStarted(RoundStarted)
    case agentThinking(AgentActivity)
    case agentTyping(AgentActivity)
    case agentPassed(AgentActivity)
    case messageCompleted(Message)
    case roundCompleted(RoundCompleted)
    case pausePending(RoomPausePending)
    case paused(RoomStateChanged)
    case resumed(RoomStateChanged)
    case ended(RoomStateChanged)
    case unknown
}

// MARK: - Envelope

public struct EventEnvelope: Equatable, Sendable {
    public let eventId: UUID
    public let roomId: UUID
    public let sequence: Int
    public let createdAt: Date
    public let eventType: String
    public let payload: EventPayload

    public init(
        eventId: UUID,
        roomId: UUID,
        sequence: Int,
        createdAt: Date,
        eventType: String,
        payload: EventPayload
    ) {
        self.eventId = eventId
        self.roomId = roomId
        self.sequence = sequence
        self.createdAt = createdAt
        self.eventType = eventType
        self.payload = payload
    }

    public static func decode(from data: Data) throws -> EventEnvelope {
        try JSONDecoder.roundtable.decode(EventEnvelope.self, from: data)
    }
}

extension EventEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case eventId
        case roomId
        case sequence
        case createdAt
        case eventType
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decode(UUID.self, forKey: .eventId)
        roomId = try container.decode(UUID.self, forKey: .roomId)
        sequence = try container.decode(Int.self, forKey: .sequence)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        eventType = try container.decode(String.self, forKey: .eventType)
        payload = try Self.decodePayload(eventType: eventType, container: container)
    }

    private static func decodePayload(
        eventType: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EventPayload {
        switch eventType {
        case "room.joined":
            return .joined(try container.decode(JoinedRoom.self, forKey: .payload))
        case "round.started", "round.completed":
            return try decodeRoundPayload(eventType: eventType, container: container)
        case "agent.thinking", "agent.typing", "agent.passed":
            return try decodeAgentPayload(eventType: eventType, container: container)
        case "message.completed":
            let completed = try container.decode(MessageCompletedPayload.self, forKey: .payload)
            return .messageCompleted(completed.message)
        case "room.pause_pending", "room.paused", "room.resumed", "room.ended":
            return try decodeRoomControlPayload(eventType: eventType, container: container)
        default:
            // Unknown events must not break the stream: the server may ship
            // new event types before the client is updated.
            return .unknown
        }
    }

    private static func decodeRoundPayload(
        eventType: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EventPayload {
        switch eventType {
        case "round.started":
            return .roundStarted(try container.decode(RoundStarted.self, forKey: .payload))
        default:
            return .roundCompleted(try container.decode(RoundCompleted.self, forKey: .payload))
        }
    }

    private static func decodeAgentPayload(
        eventType: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EventPayload {
        let activity = try container.decode(AgentActivity.self, forKey: .payload)
        switch eventType {
        case "agent.thinking":
            return .agentThinking(activity)
        case "agent.typing":
            return .agentTyping(activity)
        default:
            return .agentPassed(activity)
        }
    }

    private static func decodeRoomControlPayload(
        eventType: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> EventPayload {
        if eventType == "room.pause_pending" {
            return .pausePending(
                try container.decode(RoomPausePending.self, forKey: .payload)
            )
        }
        let state = try container.decode(RoomStateChanged.self, forKey: .payload)
        switch eventType {
        case "room.paused":
            return .paused(state)
        case "room.resumed":
            return .resumed(state)
        default:
            return .ended(state)
        }
    }
}

// MARK: - JSON coding

extension JSONDecoder {
    /// Single place that pins the wire format from docs/protocol.md.
    static var roundtable: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: raw) {
                return date
            }
            if let date = ISO8601DateFormatter.internetDateTime.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported ISO 8601 timestamp: \(raw)"
                )
            )
        }
        return decoder
    }
}

extension JSONEncoder {
    static var roundtable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.wireFormat.string(from: date))
        }
        return encoder
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let wireFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
