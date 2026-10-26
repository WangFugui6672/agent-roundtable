import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

extension RealTurnTests {
    func testSecondRoundRetriesInvalidStructuredOutputOnceAndContinues() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        let reviewMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000BB")!
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
        let summaryJSON = """
        {
          "consensus": [
            {"text": "验证需要先定义停止条件。", "reference_indexes": [2]}
          ],
          "dissent": [],
          "recommendations": [],
          "unresolved": []
        }
        """
        var responses = secondRoundResponses(
            skepticMessageID: skepticMessageID,
            reviewMessageID: reviewMessageID
        )
        responses.append(
            summaryResponse(sequence: 14, referenceMessageID: reviewMessageID)
        )
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [invalidJSON],
                [validJSON],
                [summaryJSON]
            ],
            usageByAttempt: [
                ProviderUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12)
            ],
            responses: responses
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
        XCTAssertEqual(recordedAttempts, 6)
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
        let usage = try XCTUnwrap(messageBodies.last?["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 20)
        XCTAssertEqual(usage["output_tokens"] as? Int, 4)
        XCTAssertEqual(usage["retry_count"] as? Int, 1)
    }

    func testSecondRoundStopsAfterOneStructuredRetry() async throws {
        let invalidJSON = #"{"message_type":"challenge"}"#
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        var responses = secondRoundResponses(skepticMessageID: skepticMessageID)
        responses.insert(
            failureResponse(
                advocate,
                code: "provider_invalid_response",
                retryable: true,
                sequence: 11,
                round: 2
            ),
            at: 7
        )
        let (model, _) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [invalidJSON],
                [invalidJSON]
            ],
            responses: responses
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(agentID, message, _) = model.turnState else {
            return XCTFail("expected structured failure, got \(model.turnState)")
        }
        XCTAssertEqual(agentID, advocate.agentID)
        XCTAssertTrue(message.contains("已重试一次"))
        XCTAssertEqual(model.failureCode, "provider_invalid_response")
        XCTAssertTrue(model.failureRetryable)
        let recordedAttempts = await lastStream?.recordedAttemptCount()
        XCTAssertEqual(recordedAttempts, 5)
        XCTAssertEqual(model.room?.messages.count, 2)
        XCTAssertEqual(model.room?.failures.count, 1)
    }

    func testSecondRoundAutomaticallyGeneratesAndSubmitsAStructuredSummary() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        let reviewMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000BB")!
        let reviewJSON = """
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
        let summaryJSON = """
        {
          "consensus": [
            {"text": "先完成可验证的小实验。", "reference_indexes": [0]}
          ],
          "dissent": [
            {"text": "验证成本仍然可能被低估。", "reference_indexes": [1]}
          ],
          "recommendations": [],
          "unresolved": []
        }
        """
        var responses = secondRoundResponses(
            skepticMessageID: skepticMessageID,
            reviewMessageID: reviewMessageID
        )
        responses.append(
            summaryResponse(sequence: 14, referenceMessageID: reviewMessageID)
        )
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [reviewJSON],
                [summaryJSON]
            ],
            responses: responses
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertEqual(model.room?.status, .completed)
        XCTAssertEqual(model.room?.summary?.degraded, false)
        XCTAssertEqual(
            model.room?.summary?.consensus.first?.referenceMessageIds.first,
            reviewMessageID
        )
        let requests = await transport.recordedRequests()
        let summaryRequests = requests.filter {
            $0.url?.path.hasSuffix("/summary") == true
        }
        XCTAssertEqual(summaryRequests.count, 1)
        let body = try XCTUnwrap(summaryRequests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["expected_version"] as? Int, 0)
        XCTAssertEqual(json["degraded"] as? Bool, false)
        XCTAssertNil(json["api_key"])
    }

    func testInvalidSummaryFallsBackToCitedRuleBasedContentAfterOneRetry() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000AA")!
        let reviewMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000BB")!
        let reviewJSON = """
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
        let invalidSummary = #"{"consensus":[]}"#
        var responses = secondRoundResponses(
            skepticMessageID: skepticMessageID,
            reviewMessageID: reviewMessageID
        )
        responses.append(
            summaryResponse(
                sequence: 14,
                referenceMessageID: reviewMessageID,
                degraded: true
            )
        )
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义停止条件。"],
                ["PASS"],
                [reviewJSON],
                [invalidSummary],
                [invalidSummary]
            ],
            responses: responses
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertEqual(model.room?.status, .completed)
        XCTAssertEqual(model.room?.summary?.degraded, true)
        let requests = await transport.recordedRequests()
        let summaryRequest = try XCTUnwrap(
            requests.first { $0.url?.path.hasSuffix("/summary") == true }
        )
        let body = try XCTUnwrap(summaryRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["degraded"] as? Bool, true)
        let referenced = Set(
            try summaryReferenceIDs(in: json)
        )
        let storedMessageIDs = Set(model.room?.messages.map(\.id) ?? [])
        XCTAssertTrue(referenced.isSubset(of: storedMessageIDs))
        let recordedAttempts = await lastStream?.recordedAttemptCount()
        XCTAssertEqual(recordedAttempts, 6)
    }

    private func summaryReferenceIDs(in body: [String: Any]) throws -> [UUID] {
        let keys = ["consensus", "dissent", "recommendations", "unresolved"]
        return try keys.flatMap { key in
            let items = body[key] as? [[String: Any]] ?? []
            return try items.flatMap { item in
                let raw = item["reference_message_ids"] as? [String] ?? []
                return try raw.map {
                    try XCTUnwrap(UUID(uuidString: $0))
                }
            }
        }
    }

    func testRegenerateSummaryUsesTheCurrentVersion() async throws {
        let referenceID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000CC")!
        let transport = TurnTransport(responses: [
            summaryResponse(
                sequence: 2,
                referenceMessageID: referenceID,
                version: 2
            )
        ])
        let model = AppModel(
            defaults: defaults,
            providerStore: ProviderStore(
                secrets: secrets,
                storage: UserDefaultsProviderStorage(defaults: defaults)
            ),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            )
        )
        model.present(snapshot())
        try model.repository.apply(
            EventEnvelope(
                eventId: UUID(),
                roomId: roomID,
                sequence: 1,
                createdAt: Date(),
                eventType: "summary.completed",
                payload: .summaryCompleted(
                    SummaryCompleted(
                        summary: RoundSummary(
                            id: UUID(),
                            version: 1,
                            degraded: true,
                            consensus: [
                                SummaryItem(
                                    text: "已有结论。",
                                    referenceMessageIds: [referenceID]
                                )
                            ],
                            dissent: [],
                            recommendations: [],
                            unresolved: [],
                            createdAt: Date(),
                            updatedAt: Date()
                        )
                    )
                )
            )
        )
        model.regenerateSummary()
        for _ in 0 ..< 100
        where model.summaryState != SummaryGenerationState.completed(version: 2) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(model.room?.summary?.version, 2)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(
            requests.first { $0.url?.path.hasSuffix("/summary") == true }
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["expected_version"] as? Int, 1)
    }
}
