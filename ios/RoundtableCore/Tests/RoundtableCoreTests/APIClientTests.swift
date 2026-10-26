import XCTest

@testable import RoundtableCore

actor StubTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(data: Data(), statusCode: 500)
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let guestSessionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000009")!

    func testCreatesGuestSessionWithoutAuthHeader() async throws {
        let response = """
        {"id": "AAAAAAAA-0000-4000-8000-000000000009", "created_at": "2026-10-26T01:02:03.456Z"}
        """
        let transport = StubTransport(responses: [.init(data: Data(response.utf8), statusCode: 201)])
        let client = APIClient(baseURL: baseURL, transport: transport)

        let session = try await client.createGuestSession()

        XCTAssertEqual(session.id, guestSessionID)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/api/v1/guest-sessions")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Guest-Session"))
    }

    func testCreatesRoundtableWithGuestHeaderAndSnakeCaseBody() async throws {
        let transport = StubTransport(
            responses: [.init(data: Data(Fixtures.snapshotJSON.utf8), statusCode: 201)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let snapshot = try await client.createRoundtable(
            topic: "该不该把验证周期压缩到两周？",
            agentProfileIds: [Fixtures.advocateID]
        )

        XCTAssertEqual(snapshot.id, Fixtures.roomID)
        XCTAssertEqual(snapshot.participants.count, 3)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/roundtables")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Guest-Session"), guestSessionID.uuidString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["topic"] as? String, "该不该把验证周期压缩到两周？")
        let ids = try XCTUnwrap(json["agent_profile_ids"] as? [String])
        XCTAssertEqual(ids, [Fixtures.advocateID.uuidString])
    }

    func testFetchesAgentProfiles() async throws {
        let response = "[" + """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "key": "advocate",
          "name": "方案派",
          "tagline": "先给出可执行的方案，再谈权衡。",
          "expertise": "方案设计",
          "goal": "提出可执行方案。",
          "default_stance": "倾向推进。",
          "style": "直接。",
          "banned_behaviors": [],
          "max_reply_chars": 180
        }
        """ + "]"
        let transport = StubTransport(responses: [.init(data: Data(response.utf8), statusCode: 200)])
        let client = APIClient(baseURL: baseURL, transport: transport)

        let profiles = try await client.fetchAgentProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].key, "advocate")
        XCTAssertEqual(profiles[0].maxReplyChars, 180)
    }

    func testSurfacesServerErrorEnvelope() async throws {
        let response = """
        {"error": {"code": "validation_error", "message": "必须选择 3 个不同的 Agent。", "details": {}}}
        """
        let transport = StubTransport(responses: [.init(data: Data(response.utf8), statusCode: 400)])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        do {
            _ = try await client.createRoundtable(topic: "x", agentProfileIds: [])
            XCTFail("expected the call to throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "validation_error")
            XCTAssertEqual(error.message, "必须选择 3 个不同的 Agent。")
            XCTAssertEqual(error.statusCode, 400)
        }
    }

    func testBuildsWebSocketURLWithCursor() throws {
        let url = try XCTUnwrap(
            RoundtableStream.makeURL(
                baseURL: baseURL,
                roomID: Fixtures.roomID,
                guestSessionID: guestSessionID,
                cursor: 7
            )
        )

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertTrue(
            url.path.hasPrefix("/ws/v1/roundtables/\(Fixtures.roomID.uuidString)"),
            "unexpected path: \(url.path)"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(query["guest_session"], guestSessionID.uuidString)
        XCTAssertEqual(query["cursor"], "7")
    }
}
