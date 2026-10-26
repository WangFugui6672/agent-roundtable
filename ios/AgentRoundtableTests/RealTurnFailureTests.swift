import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

@MainActor
final class RealTurnFailureTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: TurnSecretStore!

    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    private let advocate = TurnFixture(
        id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000011")!,
        agentID: UUID(uuidString: "D00D0000-0000-4000-8000-000000000003")!,
        position: 0,
        key: "advocate",
        name: "方案派"
    )
    private let skeptic = TurnFixture(
        id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000012")!,
        agentID: UUID(uuidString: "E00E0000-0000-4000-8000-000000000005")!,
        position: 1,
        key: "skeptic",
        name: "质疑派"
    )
    private let experience = TurnFixture(
        id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000013")!,
        agentID: UUID(uuidString: "F00F0000-0000-4000-8000-000000000006")!,
        position: 2,
        key: "experience",
        name: "体验派"
    )

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.failure.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = TurnSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testProviderUsageIsReportedWithSuccessfulMessages() async throws {
        let usage = ProviderUsage(inputTokens: 120, outputTokens: 30, totalTokens: 150)
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义否证指标。"],
                ["PASS"]
            ],
            usageByAttempt: [usage],
            responses: firstRoundResponses()
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        let requests = await transport.recordedRequests()
        let messageBodies = requests
            .filter { $0.url?.path.hasSuffix("/messages") == true }
            .compactMap(\.httpBody)
            .compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        XCTAssertEqual(messageBodies.count, 2)
        for body in messageBodies {
            let reported = try XCTUnwrap(body["usage"] as? [String: Any])
            XCTAssertEqual(reported["input_tokens"] as? Int, 120)
            XCTAssertEqual(reported["output_tokens"] as? Int, 30)
            XCTAssertEqual(reported["retry_count"] as? Int, 0)
            XCTAssertGreaterThanOrEqual(reported["latency_ms"] as? Int ?? -1, 0)
        }
    }

    func testProviderFailureIsReportedOnceAndDoesNotSubmit() async throws {
        let (model, transport) = makeModel(
            deltasByAttempt: [[]],
            statusCodes: [401],
            responses: [
                nextResponse(advocate, sequence: 1, startsRound: true),
                failureResponse(
                    advocate,
                    code: "provider_unauthorized",
                    retryable: false,
                    sequence: 3
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("API Key"))
        XCTAssertEqual(model.failureCode, "provider_unauthorized")
        XCTAssertFalse(model.failureRetryable)
        XCTAssertNil(model.scheduledTurn)
        XCTAssertEqual(model.room?.failures.count, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url?.path.hasSuffix("/turns/next") == true)
        XCTAssertTrue(requests[1].url?.path.hasSuffix("/turns/fail") == true)
        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["failure_code"] as? String, "provider_unauthorized")
        XCTAssertEqual(json["retryable"] as? Bool, false)
        XCTAssertNil(json["api_key"])
        XCTAssertTrue(model.room?.messages.isEmpty == true)
    }

    func testNonRetryableFailureCannotStartAnotherTurn() async throws {
        let (model, transport) = makeModel(
            deltasByAttempt: [[]],
            statusCodes: [401],
            responses: [
                nextResponse(advocate, sequence: 1, startsRound: true),
                failureResponse(
                    advocate,
                    code: "provider_unauthorized",
                    retryable: false,
                    sequence: 3
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()
        await model.retryTurn()

        guard case .failed = model.turnState else {
            return XCTFail("expected the non-retryable failure to remain")
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/fail"
            ]
        )
    }

    private func makeModel(
        deltasByAttempt: [[String]],
        usageByAttempt: [ProviderUsage?] = [],
        statusCodes: [Int] = [200],
        responses: [HTTPResponse]
    ) -> (AppModel, TurnTransport) {
        let transport = TurnTransport(responses: responses)
        let store = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        let stream = TurnLineStream(
            deltasByAttempt: deltasByAttempt,
            usageByAttempt: usageByAttempt,
            statusCodes: statusCodes
        )
        let model = AppModel(
            defaults: defaults,
            providerStore: store,
            chatClient: ProviderChatClient(streaming: stream),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            )
        )
        return (model, transport)
    }

    private func snapshot() -> RoundtableSnapshot {
        let participants = [advocate, skeptic, experience].map { turn in
            Participant(
                id: turn.agentID,
                position: turn.position,
                state: .waiting,
                agent: profile(for: turn)
            )
        }
        return RoundtableSnapshot(
            id: roomID,
            topic: "该不该把验证周期压缩到两周？",
            status: .ready,
            mode: "decision",
            maxRounds: 2,
            currentRound: 0,
            lastSequence: 0,
            createdAt: Date(),
            updatedAt: Date(),
            participants: participants
        )
    }

    private func profile(for turn: TurnFixture) -> AgentProfile {
        AgentProfile(
            id: UUID(),
            key: turn.key,
            name: turn.name,
            tagline: "定位",
            expertise: "专长",
            goal: "目标",
            defaultStance: "默认立场",
            style: "直接",
            bannedBehaviors: [],
            maxReplyChars: 180
        )
    }

    private func enableProvider(on model: AppModel) {
        model.saveProvider(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-test-turn"
            )
        )
    }

    private func firstRoundResponses() -> [HTTPResponse] {
        let proposal = ReplyFixture(
            messageType: "proposal",
            stance: nil,
            claim: "先做两周实验",
            body: "先做两周实验。",
            sequence: 3
        )
        let challenge = ReplyFixture(
            messageType: "challenge",
            stance: "challenge",
            claim: "必须先定义否证指标",
            body: "必须先定义否证指标。",
            sequence: 5
        )
        return [
            nextResponse(advocate, sequence: 1, startsRound: true),
            completedResponse(advocate, reply: proposal),
            nextResponse(skeptic, sequence: 4),
            completedResponse(skeptic, reply: challenge),
            nextResponse(experience, sequence: 6),
            passResponse(experience, sequence: 7),
            roundCompletedResponse(sequence: 8)
        ]
    }

    private func nextResponse(
        _ turn: TurnFixture,
        sequence: Int,
        startsRound: Bool = false
    ) -> HTTPResponse {
        var events: [[String: Any]] = []
        if startsRound {
            events.append(
                event(
                    "round.started",
                    sequence: sequence,
                    payload: ["round": 1, "max_rounds": 2, "topic": "议题"]
                )
            )
        }
        events.append(
            event(
                "agent.thinking",
                sequence: sequence + (startsRound ? 1 : 0),
                payload: [
                    "turn_id": turn.id.uuidString,
                    "round": 1,
                    "agent_id": turn.agentID.uuidString,
                    "agent_name": turn.name
                ]
            )
        )
        return jsonResponse(
            ["round": 1, "turn": turn.wire(round: 1), "events": events],
            statusCode: 200
        )
    }

    private func completedResponse(_ turn: TurnFixture, reply: ReplyFixture) -> HTTPResponse {
        let message: [String: Any] = [
            "id": reply.messageID.uuidString,
            "turn_id": turn.id.uuidString,
            "round_number": reply.roundNumber,
            "author": [
                "roundtable_agent_id": turn.agentID.uuidString,
                "agent_key": turn.key,
                "name": turn.name
            ],
            "message_type": reply.messageType,
            "claim": reply.claim,
            "body": reply.body,
            "stance": reply.stance ?? NSNull(),
            "references": reply.references.map(\.uuidString),
            "challenge_target_agent_id": reply.challengeTargetAgentID?.uuidString ?? NSNull(),
            "confidence": 0.6,
            "created_at": "2026-10-26T01:02:04.000Z"
        ]
        return jsonResponse(
            event("message.completed", sequence: reply.sequence, payload: ["message": message]),
            statusCode: 201
        )
    }

    private func passResponse(_ turn: TurnFixture, sequence: Int) -> HTTPResponse {
        jsonResponse(
            event(
                "agent.passed",
                sequence: sequence,
                payload: [
                    "turn_id": turn.id.uuidString,
                    "round": 1,
                    "agent_id": turn.agentID.uuidString,
                    "agent_name": turn.name
                ]
            ),
            statusCode: 201
        )
    }

    private func roundCompletedResponse(sequence: Int) -> HTTPResponse {
        jsonResponse(
            [
                "round": 1,
                "turn": NSNull(),
                "events": [event("round.completed", sequence: sequence, payload: ["round": 1])]
            ],
            statusCode: 200
        )
    }

    private func failureResponse(
        _ turn: TurnFixture,
        code: String,
        retryable: Bool,
        sequence: Int
    ) -> HTTPResponse {
        jsonResponse(
            event(
                "agent.failed",
                sequence: sequence,
                payload: [
                    "turn_id": turn.id.uuidString,
                    "round": 1,
                    "agent_id": turn.agentID.uuidString,
                    "agent_name": turn.name,
                    "failure_code": code,
                    "message": "Provider 请求失败。",
                    "retryable": retryable,
                    "partial": NSNull()
                ]
            ),
            statusCode: 201
        )
    }

    private func event(_ type: String, sequence: Int, payload: [String: Any]) -> [String: Any] {
        [
            "event_id": UUID().uuidString,
            "room_id": roomID.uuidString,
            "sequence": sequence,
            "created_at": "2026-10-26T01:02:03.456Z",
            "event_type": type,
            "payload": payload
        ]
    }

    private func jsonResponse(_ object: Any, statusCode: Int) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(data: data, statusCode: statusCode)
    }
}
