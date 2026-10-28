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
        let challengeTargetAgentId: String?
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

        guard let wire = jsonPayloadCandidates(text).lazy.compactMap({ payload in
            try? JSONDecoder.roundtable.decode(
                WireReply.self,
                from: Data(payload.utf8)
            )
        }).first else {
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
        let challengeTargetAgentId = try resolveChallengeTargetID(
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
            challengeTargetAgentId: challengeTargetAgentId,
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

    private static func jsonPayloadCandidates(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        candidates.append(contentsOf: balancedJSONObjects(in: trimmed))

        var seen = Set<String>()
        return candidates.filter { candidate in
            !candidate.isEmpty && seen.insert(candidate).inserted
        }
    }

    private static func balancedJSONObjects(in text: String) -> [String] {
        let characters = Array(text)
        var objects: [String] = []
        var start: Int?
        var depth = 0
        var isInString = false
        var isEscaped = false

        for (index, character) in characters.enumerated() {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == "{" {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(String(characters[objectStart ... index]))
                    start = nil
                }
            }
        }
        return objects
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

    private static func resolveChallengeTargetID(
        _ rawTarget: String?,
        stance: Stance,
        participant: Participant,
        reference: Message
    ) throws -> UUID? {
        let target = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stance != .challenge {
            guard target.isEmpty else {
                throw StructuredReplyError.invalidField("challenge_target_agent_id")
            }
            return nil
        }
        guard !target.isEmpty,
              let authorID = reference.author.roundtableAgentId,
              authorID != participant.id
        else {
            throw StructuredReplyError.invalidField("challenge_target_agent_id")
        }

        let matchesID = UUID(uuidString: target) == authorID
        let matchesName = target.caseInsensitiveCompare(reference.author.name) == .orderedSame
        let matchesKey = reference.author.agentKey.map {
            target.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
        guard matchesID || matchesName || matchesKey else {
            throw StructuredReplyError.invalidField("challenge_target_agent_id")
        }
        return authorID
    }
}
