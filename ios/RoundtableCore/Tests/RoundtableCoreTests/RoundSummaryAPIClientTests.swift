import Foundation
import XCTest

@testable import RoundtableCore

final class RoundSummaryAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let guestSessionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000009")!

    func testSubmitsVersionedSummaryWithoutLeakingProviderSecrets() async throws {
        let snapshot = Fixtures.snapshotJSON.replacingOccurrences(
            of: "\"status\": \"ready\"",
            with: "\"status\": \"completed\""
        )
        let response = """
        {
          "roundtable": \(snapshot),
          "summary": \(Fixtures.summaryJSON),
          "events": [
            {
              "event_id": "0F9A0000-0000-4000-8000-000000000099",
              "room_id": "C0DEC0DE-0000-4000-8000-000000000001",
              "sequence": 21,
              "created_at": "2026-10-26T01:05:03.456Z",
              "event_type": "summary.completed",
              "payload": {"summary": \(Fixtures.summaryJSON)}
            }
          ]
        }
        """
        let transport = StubTransport(responses: [
            .init(data: Data(response.utf8), statusCode: 201)
        ])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )
        let submission = RoundSummarySubmission(
            expectedVersion: 0,
            degraded: false,
            consensus: [
                SummaryItem(
                    text: "先完成可验证的小实验。",
                    referenceMessageIds: [Fixtures.messageID]
                )
            ],
            dissent: [],
            recommendations: [],
            unresolved: []
        )

        let result = try await client.submitSummary(
            roundtableID: Fixtures.roomID,
            submission: submission
        )

        XCTAssertEqual(result.summary.id, Fixtures.summaryID)
        XCTAssertEqual(result.events.map(\.eventType), ["summary.completed"])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/summary"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["expected_version"] as? Int, 0)
        XCTAssertEqual(json["degraded"] as? Bool, false)
        XCTAssertNil(json["api_key"])
    }

    func testCreatesFollowUpRoundtableWithOnlyTopicAndParentPath() async throws {
        let transport = StubTransport(responses: [
            .init(data: Data(Fixtures.snapshotJSON.utf8), statusCode: 201)
        ])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let snapshot = try await client.createFollowUp(
            parentRoundtableID: Fixtures.roomID,
            topic: "还应该马上扩大验证范围吗？"
        )

        XCTAssertEqual(snapshot.id, Fixtures.roomID)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/follow-ups"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["topic"] as? String, "还应该马上扩大验证范围吗？")
        XCTAssertEqual(json.count, 1)
    }
}
