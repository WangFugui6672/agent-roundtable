import XCTest

@testable import RoundtableCore

final class UserControlAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let guestSessionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000009")!

    func testSendsUserMessageWithExplicitMentionAndDecodesRoomState() async throws {
        let snapshot = Fixtures.snapshotJSON.replacingOccurrences(
            of: "\"last_sequence\": 0,",
            with: "\"last_sequence\": 2,\n  \"pause_pending\": true,"
        )
        let event = String(
            data: Fixtures.envelope(
                eventType: "room.pause_pending",
                sequence: 2,
                payload: "{\"turn_id\": \"\(Fixtures.turnID.uuidString)\"}"
            ),
            encoding: .utf8
        ) ?? ""
        let response = "{\"roundtable\": \(snapshot), \"events\": [\(event)]}"
        let transport = StubTransport(
            responses: [.init(data: Data(response.utf8), statusCode: 201)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let result = try await client.sendUserMessage(
            roundtableID: Fixtures.roomID,
            body: "体验派先回应一下。",
            mentionedAgentIDs: [Fixtures.advocateID]
        )

        XCTAssertEqual(result.roundtable.pausePending, true)
        XCTAssertEqual(result.events.map(\.eventType), ["room.pause_pending"])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/user-messages"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["body"] as? String, "体验派先回应一下。")
        XCTAssertEqual(json["mentioned_agent_ids"] as? [String], [Fixtures.advocateID.uuidString])
    }

    func testSendsPauseResumeAndEndCommandsToTheirEndpoints() async throws {
        let response = Data(
            "{\"roundtable\": \(Fixtures.snapshotJSON), \"events\": []}".utf8
        )
        let transport = StubTransport(
            responses: [
                .init(data: response, statusCode: 200),
                .init(data: response, statusCode: 200),
                .init(data: response, statusCode: 200)
            ]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        _ = try await client.pauseRoundtable(roundtableID: Fixtures.roomID)
        _ = try await client.resumeRoundtable(roundtableID: Fixtures.roomID)
        _ = try await client.endRoundtable(roundtableID: Fixtures.roomID)

        let paths = await transport.recordedRequests().map(\.url?.path)
        XCTAssertEqual(
            paths,
            ["pause", "resume", "end"].map {
                "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/\($0)"
            }
        )
    }
}
