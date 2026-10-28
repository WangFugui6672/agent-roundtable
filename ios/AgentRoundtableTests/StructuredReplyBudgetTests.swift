import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

private actor StructuredOutputBudgetStream: LineStreaming {
    private let plainReplies: [String]
    private let validStructuredReply: String
    private let truncatedStructuredReply: String
    private let structuredFinishReasons: [String?]
    private var attempt = 0
    private(set) var requests: [URLRequest] = []

    init(
        plainReplies: [String],
        validStructuredReply: String,
        truncatedStructuredReply: String,
        structuredFinishReasons: [String?] = []
    ) {
        self.plainReplies = plainReplies
        self.validStructuredReply = validStructuredReply
        self.truncatedStructuredReply = truncatedStructuredReply
        self.structuredFinishReasons = structuredFinishReasons
    }

    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        requests.append(request)
        let responseText: String
        var finishReason: String?
        if attempt < plainReplies.count {
            responseText = plainReplies[attempt]
        } else {
            let maxTokens = request.httpBody
                .flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
                .flatMap { $0["max_tokens"] as? Int } ?? 0
            responseText = maxTokens >= 1_200
                ? validStructuredReply
                : truncatedStructuredReply
            let structuredAttempt = attempt - plainReplies.count
            if structuredFinishReasons.indices.contains(structuredAttempt) {
                finishReason = structuredFinishReasons[structuredAttempt]
            }
        }
        attempt += 1

        let choice: [String: Any] = [
            "delta": ["content": responseText],
            "finish_reason": finishReason ?? NSNull()
        ]
        let payload: [String: Any] = [
            "choices": [choice]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = "data: \(try XCTUnwrap(String(data: data, encoding: .utf8)))"
        return StreamingResponse(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                continuation.yield(line)
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
        )
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

extension RealTurnTests {
    func testSecondRoundUsesTokenBudgetLargeEnoughForStructuredOutput() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000EE")!
        let reviewMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000FF")!
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
        let truncatedJSON = String(validJSON.prefix(validJSON.count / 2))
        let stream = StructuredOutputBudgetStream(
            plainReplies: [
                "先做两周实验。",
                "必须先定义停止条件。",
                "PASS"
            ],
            validStructuredReply: validJSON,
            truncatedStructuredReply: truncatedJSON
        )
        var responses = secondRoundResponses(
            skepticMessageID: skepticMessageID,
            reviewMessageID: reviewMessageID
        )
        responses.append(
            summaryResponse(sequence: 14, referenceMessageID: reviewMessageID)
        )
        let (model, _) = makeModel(
            deltasByAttempt: [],
            responses: responses,
            streaming: stream
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertEqual(model.room?.currentRound, 2)
        XCTAssertEqual(model.room?.messages.count, 3)
        XCTAssertNil(model.failureCode)
        let requests = await stream.recordedRequests()
        let structuredRequest = try XCTUnwrap(requests.dropFirst(3).first)
        let body = try XCTUnwrap(structuredRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertGreaterThanOrEqual(json["max_tokens"] as? Int ?? 0, 1_200)
    }

    func testSecondRoundRetriesWhenProviderReportsLengthTruncation() async throws {
        let skepticMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000E1")!
        let reviewMessageID = UUID(uuidString: "6F0E0000-0000-4000-8000-0000000000E2")!
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
        let stream = StructuredOutputBudgetStream(
            plainReplies: [
                "先做两周实验。",
                "必须先定义停止条件。",
                "PASS"
            ],
            validStructuredReply: validJSON,
            truncatedStructuredReply: validJSON,
            structuredFinishReasons: ["length", "stop"]
        )
        var responses = secondRoundResponses(
            skepticMessageID: skepticMessageID,
            reviewMessageID: reviewMessageID
        )
        responses.append(
            summaryResponse(sequence: 14, referenceMessageID: reviewMessageID)
        )
        let (model, _) = makeModel(
            deltasByAttempt: [],
            responses: responses,
            streaming: stream
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertNil(model.failureCode)
        XCTAssertEqual(model.room?.messages.count, 3)
        let requests = await stream.recordedRequests()
        let structuredRequests = Array(requests.dropFirst(3).prefix(2))
        XCTAssertEqual(structuredRequests.count, 2)
        let maxTokens = try structuredRequests.map { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return json["max_tokens"] as? Int
        }
        XCTAssertEqual(maxTokens, [1_200, 2_000])
    }
}
