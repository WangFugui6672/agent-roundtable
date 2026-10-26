import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

extension RealTurnTests {
    func testSecondRoundRetriesInvalidStructuredOutputOnceAndContinues() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        let invalidJSON = #"{"message_type":"challenge"}"#
        let validJSON = """
        {
          "message_type": "challenge",
          "claim": "验证成本仍然被低估。",
          "body": "我质疑这个观点，因为团队注意力也是成本。",
          "stance": "challenge",
          "reference_message_id": "\(skepticMessageID.uuidString)",
          "challenge_target_agent_id": "\(skeptic.agentID.uuidString)",
          "confidence": 0.78
        }
        """
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [invalidJSON],
                [validJSON]
            ],
            responses: secondRoundResponses(skepticMessageID: skepticMessageID)
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertEqual(model.turnState, .roundCompleted(round: 2))
        XCTAssertEqual(model.room?.currentRound, 2)
        XCTAssertEqual(model.room?.messages.count, 3)
        let review = try XCTUnwrap(model.room?.messages.last)
        XCTAssertEqual(review.roundNumber, 2)
        XCTAssertEqual(review.messageType, .challenge)
        XCTAssertEqual(review.stance, .challenge)
        XCTAssertEqual(review.references, [skepticMessageID])
        XCTAssertEqual(review.challengeTargetAgentId, skeptic.agentID)
        let recordedAttempts = await lastStream?.recordedAttemptCount()
        XCTAssertEqual(recordedAttempts, 5)
        let requests = await transport.recordedRequests()
        let messageBodies = requests
            .filter { $0.url?.path.hasSuffix("/messages") == true }
            .compactMap(\.httpBody)
            .compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        XCTAssertEqual(messageBodies.count, 3)
        XCTAssertEqual(messageBodies.last?["message_type"] as? String, "challenge")
        XCTAssertEqual(messageBodies.last?["stance"] as? String, "challenge")
        XCTAssertEqual(
            messageBodies.last?["challenge_target_agent_id"] as? String,
            skeptic.agentID.uuidString
        )
    }

    func testSecondRoundStopsAfterOneStructuredRetry() async throws {
        let invalidJSON = #"{"message_type":"challenge"}"#
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        let (model, _) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [invalidJSON],
                [invalidJSON]
            ],
            responses: secondRoundResponses(skepticMessageID: skepticMessageID)
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(agentID, message, _) = model.turnState else {
            return XCTFail("expected structured failure, got \(model.turnState)")
        }
        XCTAssertEqual(agentID, advocate.agentID)
        XCTAssertTrue(message.contains("已重试一次"))
        let recordedAttempts = await lastStream?.recordedAttemptCount()
        XCTAssertEqual(recordedAttempts, 5)
        XCTAssertEqual(model.room?.messages.count, 2)
    }
}
