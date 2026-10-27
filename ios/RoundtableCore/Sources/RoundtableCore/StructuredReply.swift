import Foundation

public enum StructuredReplyError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case invalidField(String)
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "模型返回的结构化 JSON 无法解析。"
        case let .invalidField(field):
            return "模型返回的结构化字段无效：\(field)。"
        case let .invalidReference(reason):
            return "模型返回的引用无效：\(reason)。"
        }
    }
}

/// Parses and validates the structured JSON requested for second-round review.
///
/// Reference IDs are preferred. A zero-based `reference_index` may be used
/// instead and is resolved against the eligible earlier opinions supplied in
/// `transcript`; no reference is guessed when the model output is ambiguous.
public enum StructuredReplyParser {
    private struct WireReply: Decodable {
        let messageType: MessageType?
        let claim: String?
        let body: String?
        let stance: Stance?
        let referenceMessageId: UUID?
        let referenceIndex: Int?
        let challengeTargetAgentId: UUID?
        let confidence: Double?
    }

    private static let reviewTypes: Set<MessageType> = [
        .support, .challenge, .supplement, .question
    ]
    private static let reviewStances: Set<Stance> = [
        .support, .challenge, .supplement, .question
    ]

    public static func parse(
        _ text: String,
        participant: Participant,
        turn: ScheduledTurn,
        transcript: [Message]
    ) throws -> MessageSubmission {
        guard turn.round >= 2 else {
            throw StructuredReplyError.invalidField("round")
        }

        let candidates = referenceCandidates(
            participant: participant,
            turn: turn,
            transcript: transcript
        )
        let data = Data(jsonPayload(text).utf8)

        let wire: WireReply
        do {
            wire = try JSONDecoder.roundtable.decode(WireReply.self, from: data)
        } catch {
            throw StructuredReplyError.invalidJSON
        }

        guard let messageType = wire.messageType,
              reviewTypes.contains(messageType),
              let stance = wire.stance,
              reviewStances.contains(stance)
        else {
            throw StructuredReplyError.invalidField("message_type/stance")
        }
        guard messageType.rawValue == stance.rawValue else {
            throw StructuredReplyError.invalidField("message_type/stance")
        }

        let claim = wire.claim?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !claim.isEmpty, claim.count <= MessageComposer.Limits.claim else {
            throw StructuredReplyError.invalidField("claim")
        }

        let body = wire.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty, body.count <= participant.agent.maxReplyChars else {
            throw StructuredReplyError.invalidField("body")
        }
        guard let confidence = wire.confidence, (0 ... 1).contains(confidence) else {
            throw StructuredReplyError.invalidField("confidence")
        }

        let reference = try resolveReference(
            id: wire.referenceMessageId,
            index: wire.referenceIndex,
            candidates: candidates
        )
        try validateChallengeTarget(
            wire.challengeTargetAgentId,
            stance: stance,
            participant: participant,
            reference: reference
        )

        return MessageSubmission(
            turnId: turn.turnId,
            roundtableAgentId: participant.id,
            messageType: messageType,
            claim: claim,
            body: body,
            stance: stance,
            references: [reference.id],
            challengeTargetAgentId: wire.challengeTargetAgentId,
            confidence: confidence
        )
    }

    public static func referenceCandidates(
        participant: Participant,
        turn: ScheduledTurn,
        transcript: [Message]
    ) -> [Message] {
        transcript.filter { message in
            guard message.author.type == .agent,
                  let authorID = message.author.roundtableAgentId,
                  authorID != participant.id,
                  message.roundNumber <= turn.round,
                  [.proposal, .support, .challenge, .supplement, .question]
                    .contains(message.messageType)
            else {
                return false
            }
            return !(message.claim ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func jsonPayload(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value.removeFirst(3)
            if value.lowercased().hasPrefix("json") {
                value.removeFirst(4)
            }
            if value.hasSuffix("```") {
                value.removeLast(3)
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveReference(
        id: UUID?,
        index: Int?,
        candidates: [Message]
    ) throws -> Message {
        let byID = id.flatMap { referenceID in
            candidates.first(where: { $0.id == referenceID })
        }
        let byIndex = index.flatMap { referenceIndex in
            candidates.indices.contains(referenceIndex) ? candidates[referenceIndex] : nil
        }

        if id != nil, byID == nil {
            throw StructuredReplyError.invalidReference("ID 不存在或不是有效、更早的其他 Agent 观点")
        }
        if index != nil, byIndex == nil {
            throw StructuredReplyError.invalidReference("索引超出候选观点范围")
        }
        if let byID, let byIndex, byID.id != byIndex.id {
            throw StructuredReplyError.invalidReference("ID 与索引指向不同观点")
        }
        guard let reference = byID ?? byIndex else {
            throw StructuredReplyError.invalidReference("缺少 reference_message_id 或 reference_index")
        }
        return reference
    }

    private static func validateChallengeTarget(
        _ targetID: UUID?,
        stance: Stance,
        participant: Participant,
        reference: Message
    ) throws {
        if stance == .challenge {
            guard let targetID else {
                throw StructuredReplyError.invalidField("challenge_target_agent_id")
            }
            guard targetID != participant.id else {
                throw StructuredReplyError.invalidField("challenge_target_agent_id")
            }
            guard targetID == reference.author.roundtableAgentId else {
                throw StructuredReplyError.invalidField("challenge_target_agent_id")
            }
        } else if targetID != nil {
            throw StructuredReplyError.invalidField("challenge_target_agent_id")
        }
    }
}
