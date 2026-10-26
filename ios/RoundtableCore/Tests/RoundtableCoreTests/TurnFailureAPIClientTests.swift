import XCTest

@testable import RoundtableCore

final class TurnFailureAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let guestSessionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000009")!

    func testReportsTurnFailureWithUsageAndDecodesAgentFailure() async throws {
        let envelope = Fixtures.envelope(
            eventType: "agent.failed",
            sequence: 4,
            payload: """
            {
              "turn_id": "\(Fixtures.turnID.uuidString)",
              "round": 1,
              "agent_id": "\(Fixtures.advocateID.uuidString)",
              "agent_name": "方案派",
              "failure_code": "provider_timeout",
              "message": "请求超时，请稍后重试。",
              "retryable": true,
              "partial": "已经生成的片段"
            }
            """
        )
        let transport = StubTransport(responses: [.init(data: envelope, statusCode: 201)])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let event = try await client.reportTurnFailure(
            roundtableID: Fixtures.roomID,
            submission: TurnFailureSubmission(
                turnId: Fixtures.turnID,
                roundtableAgentId: Fixtures.advocateID,
                failureCode: "provider_timeout",
                message: "请求超时，请稍后重试。",
                retryable: true,
                partial: "已经生成的片段",
                usage: ProviderUsageReport(
                    inputTokens: 120,
                    outputTokens: 35,
                    latencyMs: 60000,
                    retryCount: 1
                )
            )
        )

        guard case let .agentFailed(failure) = event.payload else {
            return XCTFail("expected agent.failed, got \(event.payload)")
        }
        XCTAssertEqual(failure.failureCode, "provider_timeout")
        XCTAssertEqual(failure.partial, "已经生成的片段")
        XCTAssertTrue(failure.retryable)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/turns/fail"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["failure_code"] as? String, "provider_timeout")
        XCTAssertEqual(json["retryable"] as? Bool, true)
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        XCTAssertEqual(usage["latency_ms"] as? Int, 60000)
        XCTAssertNil(json["api_key"])
    }
}
