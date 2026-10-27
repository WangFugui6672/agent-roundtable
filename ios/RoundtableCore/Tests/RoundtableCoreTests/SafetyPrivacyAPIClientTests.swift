import XCTest

@testable import RoundtableCore

final class SafetyPrivacyAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let guestSessionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000009")!
    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    private let messageID = UUID(uuidString: "6F0E0000-0000-4000-8000-000000000002")!

    func testSubmitsAReasonedReportForAnAiMessage() async throws {
        let response = """
        {
          "id": "9A000000-0000-4000-8000-000000000001",
          "message_id": "\(messageID.uuidString)",
          "reason": "harassment",
          "details": "持续攻击",
          "state": "submitted",
          "created_at": "2026-10-26T01:02:03.456Z",
          "updated_at": "2026-10-26T01:02:03.456Z"
        }
        """
        let transport = StubTransport(
            responses: [.init(data: Data(response.utf8), statusCode: 201)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let report = try await client.reportMessage(
            roundtableID: roomID,
            messageID: messageID,
            reason: .harassment,
            details: "持续攻击"
        )

        XCTAssertEqual(report.messageId, messageID)
        XCTAssertEqual(report.state, .submitted)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(roomID.uuidString.lowercased())"
                + "/messages/\(messageID.uuidString.lowercased())/reports"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["reason"] as? String, "harassment")
        XCTAssertEqual(json["details"] as? String, "持续攻击")
        XCTAssertNil(json["api_key"])
    }

    func testDeletesARoundtableAndUsesGuestSessionHeader() async throws {
        let transport = StubTransport(
            responses: [.init(data: Data(), statusCode: 204)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        try await client.deleteRoundtable(id: roomID)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/roundtables/\(roomID.uuidString.lowercased())")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Guest-Session"),
            guestSessionID.uuidString
        )
        XCTAssertNil(request.httpBody)
    }
}
