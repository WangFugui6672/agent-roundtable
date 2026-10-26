import Foundation

/// Structured utterance assembled on the client and validated by the backend
/// (PRD 7.7). The API key is never part of this payload.
public struct MessageSubmission: Codable, Equatable, Sendable {
    public let turnId: UUID
    public let roundtableAgentId: UUID
    public let messageType: MessageType
    public let claim: String
    public let body: String
    public let stance: Stance?
    public let references: [UUID]
    public let challengeTargetAgentId: UUID?
    public let confidence: Double

    public init(
        turnId: UUID,
        roundtableAgentId: UUID,
        messageType: MessageType,
        claim: String,
        body: String,
        stance: Stance?,
        references: [UUID],
        challengeTargetAgentId: UUID? = nil,
        confidence: Double
    ) {
        self.turnId = turnId
        self.roundtableAgentId = roundtableAgentId
        self.messageType = messageType
        self.claim = claim
        self.body = body
        self.stance = stance
        self.references = references
        self.challengeTargetAgentId = challengeTargetAgentId
        self.confidence = confidence
    }
}

/// Builds the protocol envelope from a plain-text model reply.
///
/// Message type and stance come from the agent's preset role, so a model that
/// returns prose (or malformed JSON) can never produce an invalid message type.
public enum MessageComposer {
    /// Protocol limits (docs/protocol.md 2.7). The backend enforces the same
    /// numbers; the client stays inside them so a model overrun degrades into
    /// a shorter message instead of a failed submission.
    public enum Limits {
        public static let claim = 80
        public static let defaultConfidence = 0.6
    }

    public static func isPass(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PASS"
    }

    public static func compose(
        participant: Participant,
        text: String,
        turn: ScheduledTurn
    ) -> MessageSubmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (messageType, stance) = mapping(for: participant.agent.key)
        return MessageSubmission(
            turnId: turn.turnId,
            roundtableAgentId: participant.id,
            messageType: messageType,
            claim: claim(from: trimmed),
            body: String(trimmed.prefix(participant.agent.maxReplyChars)),
            stance: stance,
            references: [],
            confidence: Limits.defaultConfidence
        )
    }

    static func mapping(for agentKey: String) -> (MessageType, Stance?) {
        switch agentKey {
        case "advocate": return (.proposal, nil)
        case "skeptic": return (.challenge, .challenge)
        case "experience": return (.supplement, .supplement)
        default: return (.supplement, nil)
        }
    }

    static func claim(from text: String) -> String {
        let sentenceEnd: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
        let firstSentence = text.split(whereSeparator: { sentenceEnd.contains($0) }).first
        let candidate = (firstSentence.map(String.init) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = candidate.isEmpty ? text : candidate
        return String(source.prefix(Limits.claim))
    }
}
