import Foundation
import XCTest

@testable import RoundtableCore

final class HistoryVersioningAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let sessionID = UUID()
    private let messageID = UUID()

    func testFetchesHistoryAndRotatesOrDeletesSession() async throws {
        let replacement = UUID()
        let transport = StubTransport(
            responses: [
                HTTPResponse(data: Data("[\(Fixtures.snapshotJSON)]".utf8), statusCode: 200),
                HTTPResponse(
                    data: Data(
                        """
                        {"id":"\(replacement.uuidString)","created_at":"2026-10-26T01:02:03.456Z"}
                        """.utf8
                    ),
                    statusCode: 200
                ),
                HTTPResponse(data: Data(), statusCode: 204)
            ]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: sessionID
        )

        let history = try await client.fetchRoundtables()
        let rotated = try await client.rotateGuestSession()
        try await client.deleteGuestSession()

        XCTAssertEqual(history.map(\.id), [Fixtures.roomID])
        XCTAssertEqual(rotated.id, replacement)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.url?.path), [
            "/api/v1/roundtables",
            "/api/v1/guest-sessions/rotate",
            "/api/v1/guest-sessions/current"
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "DELETE"])
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "X-Guest-Session") == sessionID.uuidString
            }
        )
    }

    func testUpdatesKeyPointAndRequestsRegeneration() async throws {
        let messageJSON = Fixtures.messageJSON.replacingOccurrences(
            of: "\"message_type\": \"proposal\",",
            with: "\"message_type\": \"proposal\", \"is_key_point\": true,"
        )
        let regeneration = """
        {"round":1,"turn":null,"replacement_message_id":"\(messageID.uuidString)","events":[]}
        """
        let transport = StubTransport(
            responses: [
                HTTPResponse(data: Data(messageJSON.utf8), statusCode: 200),
                HTTPResponse(data: Data(regeneration.utf8), statusCode: 200)
            ]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: sessionID
        )

        let message = try await client.setKeyPoint(
            roundtableID: Fixtures.roomID,
            messageID: messageID,
            isKeyPoint: true
        )
        let result = try await client.regenerateMessage(
            roundtableID: Fixtures.roomID,
            messageID: messageID
        )

        XCTAssertTrue(message.isKeyPoint)
        XCTAssertNil(result.turn)
        XCTAssertEqual(result.replacementMessageId, messageID)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.first?.httpMethod, "PATCH")
        XCTAssertEqual(requests.last?.httpMethod, "POST")
        XCTAssertTrue(requests.last?.url?.path.hasSuffix("/regenerate") == true)

        let body = try XCTUnwrap(requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["is_key_point"] as? Bool, true)
    }
}
