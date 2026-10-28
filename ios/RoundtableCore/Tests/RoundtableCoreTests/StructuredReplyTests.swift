import Foundation
import XCTest

@testable import RoundtableCore

final class StructuredReplyTests: XCTestCase {
    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    private let turnID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000020")!
    private let advocateID = UUID(uuidString: "D00D0000-0000-4000-8000-000000000003")!
    private let skepticID = UUID(uuidString: "E00E0000-0000-4000-8000-000000000005")!
    private let referenceID = UUID(uuidString: "6F0E0000-0000-4000-8000-000000000004")!

    private var advocate: Participant {
        participant(id: advocateID, key: "advocate", name: "方案派", position: 0)
    }

    private var skeptic: Participant {
        participant(id: skepticID, key: "skeptic", name: "质疑派", position: 1)
    }

    private var secondRoundTurn: ScheduledTurn {
        ScheduledTurn(
            turnId: turnID,
            round: 2,
            roundtableAgentId: advocateID,
            position: 0,
            agentKey: "advocate",
            agentName: "方案派"
        )
    }

    private var earlierOpinion: Message {
        Message(
            id: referenceID,
            turnId: UUID(),
            roundNumber: 1,
            author: MessageAuthor(
                roundtableAgentId: skepticID,
                agentKey: "skeptic",
                name: "质疑派"
            ),
            messageType: .proposal,
            claim: "验证成本可能被低估。",
            body: "两周验证会占用团队注意力。",
            stance: nil,
            references: [],
            confidence: 0.7,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    func testParsesAChallengeAndMapsReferenceMessageID() throws {
        let json = """
        {
          "message_type": "challenge",
          "claim": "验证成本仍然被低估。",
          "body": "我质疑这个观点，因为团队注意力也是成本。",
          "stance": "challenge",
          "reference_message_id": "\(referenceID.uuidString)",
          "challenge_target_agent_id": "\(skepticID.uuidString)",
          "confidence": 0.78
        }
        """

        let submission = try StructuredReplyParser.parse(
            json,
            participant: advocate,
            turn: secondRoundTurn,
            transcript: [earlierOpinion]
        )

        XCTAssertEqual(submission.messageType, .challenge)
        XCTAssertEqual(submission.stance, .challenge)
        XCTAssertEqual(submission.references, [referenceID])
        XCTAssertEqual(submission.challengeTargetAgentId, skepticID)
        XCTAssertEqual(submission.claim, "验证成本仍然被低估。")
        XCTAssertEqual(submission.body, "我质疑这个观点，因为团队注意力也是成本。")
        XCTAssertEqual(submission.confidence, 0.78)
    }

    func testMapsReferenceIndexToTheOnlyEligibleOpinion() throws {
        let json = """
        {
          "message_type": "support",
          "claim": "成本约束应该写进实验前置条件。",
          "body": "我支持这个风险判断，并建议把它写成启动实验前必须满足的条件。",
          "stance": "support",
          "reference_index": 0,
          "confidence": 0.71
        }
        """

        let submission = try StructuredReplyParser.parse(
            json,
            participant: advocate,
            turn: secondRoundTurn,
            transcript: [earlierOpinion]
        )

        XCTAssertEqual(submission.references, [referenceID])
        XCTAssertNil(submission.challengeTargetAgentId)
    }

    func testRejectsAmbiguousReferenceAndMissingChallengeTarget() {
        let ambiguous = """
        {
          "message_type": "support",
          "claim": "引用必须无歧义。",
          "body": "同时给出不一致的 ID 和索引时不能猜测。",
          "stance": "support",
          "reference_message_id": "\(referenceID.uuidString)",
          "reference_index": 1,
          "confidence": 0.7
        }
        """
        XCTAssertThrowsError(
            try StructuredReplyParser.parse(
                ambiguous,
                participant: advocate,
                turn: secondRoundTurn,
                transcript: [earlierOpinion]
            )
        )

        let missingTarget = """
        {
          "message_type": "challenge",
          "claim": "质疑必须明确对象。",
          "body": "缺少 challenge_target_agent_id 时不能提交。",
          "stance": "challenge",
          "reference_message_id": "\(referenceID.uuidString)",
          "confidence": 0.7
        }
        """
        XCTAssertThrowsError(
            try StructuredReplyParser.parse(
                missingTarget,
                participant: advocate,
                turn: secondRoundTurn,
                transcript: [earlierOpinion]
            )
        )
    }

    func testExtractsJSONObjectFromProviderPreludeFenceAndTrailingExplanation() throws {
        let response = """
        我会严格按以下 JSON 格式回答：

        ```json
        {
          "message_type": "challenge",
          "claim": "验证成本仍然被低估。",
          "body": "我质疑这个观点，因为团队注意力也是成本。",
          "stance": "challenge",
          "reference_message_id": "\(referenceID.uuidString)",
          "challenge_target_agent_id": "\(skepticID.uuidString)",
          "confidence": 0.78
        }
        ```

        以上是互评结果。
        """

        let submission = try StructuredReplyParser.parse(
            response,
            participant: advocate,
            turn: secondRoundTurn,
            transcript: [earlierOpinion]
        )

        XCTAssertEqual(submission.messageType, .challenge)
        XCTAssertEqual(submission.references, [referenceID])
    }

    func testMapsChallengeTargetAgentNameToReferencedAuthorID() throws {
        let json = """
        {
          "message_type": "challenge",
          "claim": "对照店与口径检验只排除干扰，未定义有效判据。",
          "body": "我质疑这条补充仍缺否证条件，两周后很难把改善归因到快诊动作。",
          "stance": "challenge",
          "reference_message_id": "\(referenceID.uuidString)",
          "challenge_target_agent_id": "质疑派",
          "confidence": 0.72
        }
        """

        let submission = try StructuredReplyParser.parse(
            json,
            participant: advocate,
            turn: secondRoundTurn,
            transcript: [earlierOpinion]
        )

        XCTAssertEqual(submission.challengeTargetAgentId, skepticID)
    }

    func testReferenceCandidatesExcludeAgentMessagesWithoutAnAgentID() {
        let malformed = Message(
            id: UUID(),
            roundNumber: 1,
            author: MessageAuthor(type: .agent, name: "未知 Agent"),
            messageType: .proposal,
            claim: "缺少参与者身份。",
            body: "这条消息不应该成为引用候选。",
            stance: nil,
            references: [],
            createdAt: Date()
        )

        let candidates = StructuredReplyParser.referenceCandidates(
            participant: advocate,
            turn: secondRoundTurn,
            transcript: [malformed]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    private func participant(
        id: UUID,
        key: String,
        name: String,
        position: Int
    ) -> Participant {
        Participant(
            id: id,
            position: position,
            state: .waiting,
            agent: AgentProfile(
                id: UUID(),
                key: key,
                name: name,
                tagline: "定位",
                expertise: "专长",
                goal: "目标",
                defaultStance: "默认立场",
                style: "直接",
                bannedBehaviors: [],
                maxReplyChars: 180
            )
        )
    }
}
