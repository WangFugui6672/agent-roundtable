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

    func testSendsProviderMetadataWithRoundtable() async throws {
        let transport = StubTransport(
            responses: [.init(data: Data(Fixtures.providerSnapshotJSON.utf8), statusCode: 201)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let snapshot = try await client.createRoundtable(
            topic: "该不该把验证周期压缩到两周？",
            agentProfileIds: [Fixtures.advocateID],
            provider: ProviderMetadata(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat"
            )
        )

        XCTAssertEqual(snapshot.provider, ProviderMetadata(
            kind: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        ))

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let provider = try XCTUnwrap(json["provider"] as? [String: Any])
        XCTAssertEqual(provider["kind"] as? String, "deepseek")
        XCTAssertEqual(provider["base_url"] as? String, "https://api.deepseek.com/v1")
        XCTAssertEqual(provider["model"] as? String, "deepseek-chat")
        XCTAssertEqual(provider.count, 3, "provider metadata must not carry secrets")
        XCTAssertNil(provider["api_key"])
    }

    func testOmitsProviderWhenNoneConfigured() async throws {
        let transport = StubTransport(
            responses: [.init(data: Data(Fixtures.snapshotJSON.utf8), statusCode: 201)]
        )
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        _ = try await client.createRoundtable(topic: "x", agentProfileIds: [Fixtures.advocateID])

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["provider"])
    }

    func testSubmitsStructuredMessageAndDecodesEnvelope() async throws {
        let envelope = Fixtures.envelope(
            eventType: "message.completed",
            sequence: 1,
            payload: "{\"message\": \(Fixtures.messageJSON)}"
        )
        let transport = StubTransport(responses: [.init(data: envelope, statusCode: 201)])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )
        let submission = MessageSubmission(
            turnId: Fixtures.turnID,
            roundtableAgentId: Fixtures.advocateID,
            messageType: .proposal,
            claim: "先做一个两周实验",
            body: "写清假设、指标和停止条件。",
            stance: nil,
            references: [],
            confidence: 0.6
        )

        let event = try await client.submitMessage(
            roundtableID: Fixtures.roomID,
            submission: submission
        )

        XCTAssertEqual(event.eventType, "message.completed")
        XCTAssertEqual(event.sequence, 1)
        guard case let .messageCompleted(message) = event.payload else {
            return XCTFail("expected message.completed, got \(event.payload)")
        }
        XCTAssertEqual(message.id, Fixtures.messageID)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/messages"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["message_type"] as? String, "proposal")
        XCTAssertEqual(
            json["roundtable_agent_id"] as? String,
            Fixtures.advocateID.uuidString
        )
        XCTAssertEqual(json["turn_id"] as? String, Fixtures.turnID.uuidString)
        XCTAssertNil(json["api_key"])
    }

    func testRequestsAndDecodesTheNextScheduledTurn() async throws {
        let response = """
        {
          "round": 1,
          "turn": {
            "turn_id": "A11CE000-0000-4000-8000-000000000010",
            "round": 1,
            "roundtable_agent_id": "D00D0000-0000-4000-8000-000000000003",
            "position": 0,
            "agent_key": "advocate",
            "agent_name": "方案派"
          },
          "events": [
            {
              "event_id": "0F9A0000-0000-4000-8000-000000000002",
              "room_id": "C0DEC0DE-0000-4000-8000-000000000001",
              "sequence": 1,
              "created_at": "2026-10-26T01:02:03.456Z",
              "event_type": "round.started",
              "payload": {"round": 1, "max_rounds": 2, "topic": "议题"}
            },
            {
              "event_id": "0F9A0000-0000-4000-8000-000000000003",
              "room_id": "C0DEC0DE-0000-4000-8000-000000000001",
              "sequence": 2,
              "created_at": "2026-10-26T01:02:03.456Z",
              "event_type": "agent.thinking",
              "payload": {
                "turn_id": "A11CE000-0000-4000-8000-000000000010",
                "round": 1,
                "agent_id": "D00D0000-0000-4000-8000-000000000003",
                "agent_name": "方案派"
              }
            }
          ],
          "budget": {
            "max_rounds": 2,
            "max_agent_messages": 6,
            "agent_messages_used": 1,
            "max_reported_tokens": 2400,
            "reported_tokens": 2500,
            "max_duration_seconds": 90,
            "started_at": "2026-10-26T01:01:03.456Z",
            "elapsed_seconds": 60,
            "exhausted_reason": "",
            "token_source": "client_reported"
          }
        }
        """
        let transport = StubTransport(responses: [.init(data: Data(response.utf8), statusCode: 200)])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let next = try await client.nextTurn(roundtableID: Fixtures.roomID)

        XCTAssertEqual(next.round, 1)
        XCTAssertEqual(
            next.turn?.turnId,
            UUID(uuidString: "A11CE000-0000-4000-8000-000000000010")
        )
        XCTAssertEqual(next.turn?.round, 1)
        XCTAssertEqual(next.turn?.roundtableAgentId, Fixtures.advocateID)
        XCTAssertEqual(next.turn?.agentKey, "advocate")
        XCTAssertEqual(next.events.map(\.eventType), ["round.started", "agent.thinking"])
        XCTAssertEqual(next.budget?.agentMessagesUsed, 1)
        XCTAssertEqual(next.budget?.reportedTokens, 2500)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/turns/next"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Guest-Session"),
            guestSessionID.uuidString
        )
    }

    func testPassesTheCurrentTurnWithItsIdentity() async throws {
        let envelope = Fixtures.envelope(
            eventType: "agent.passed",
            sequence: 3,
            payload: """
            {
              "turn_id": "\(Fixtures.turnID.uuidString)",
              "round": 1,
              "agent_id": "\(Fixtures.advocateID.uuidString)",
              "agent_name": "方案派"
            }
            """
        )
        let transport = StubTransport(responses: [.init(data: envelope, statusCode: 201)])
        let client = APIClient(
            baseURL: baseURL,
            transport: transport,
            guestSessionId: guestSessionID
        )

        let event = try await client.passTurn(
            roundtableID: Fixtures.roomID,
            agentID: Fixtures.advocateID,
            turnID: Fixtures.turnID
        )

        XCTAssertEqual(event.eventType, "agent.passed")
        guard case let .agentPassed(activity) = event.payload else {
            return XCTFail("expected agent.passed, got \(event.payload)")
        }
        XCTAssertEqual(activity.turnId, Fixtures.turnID)
        XCTAssertEqual(activity.round, 1)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(Fixtures.roomID.uuidString.lowercased())/turns/pass"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["turn_id"] as? String, Fixtures.turnID.uuidString)
        XCTAssertEqual(
            json["roundtable_agent_id"] as? String,
            Fixtures.advocateID.uuidString
        )
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
