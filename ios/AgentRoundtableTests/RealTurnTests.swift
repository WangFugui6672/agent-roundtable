import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

@MainActor
final class RealTurnTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: TurnSecretStore!
    var lastStream: TurnLineStream?

    let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    let advocate = TurnFixture(
        id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000011")!,
        agentID: UUID(uuidString: "D00D0000-0000-4000-8000-000000000003")!,
        position: 0,
        key: "advocate",
        name: "方案派"
    )
    let skeptic = TurnFixture(
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
        suiteName = "roundtable.turn.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = TurnSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstRoundRunsEveryServerScheduledTurnInOrder() async throws {
        let (model, transport) = makeModel(
            deltasByAttempt: [
                ["先做两周实验。"],
                ["必须先定义否证指标。"],
                ["PASS"]
            ],
            responses: firstRoundResponses()
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        XCTAssertFalse(model.isFirstRoundRunning)
        XCTAssertEqual(model.turnState, .roundCompleted(round: 1))
        XCTAssertEqual(model.room?.messages.map(\.author.agentKey), ["advocate", "skeptic"])
        XCTAssertEqual(model.room?.participants.map(\.state), [.completed, .completed, .passed])
        XCTAssertNil(model.room?.activeTurn)
        assertFirstRoundRequests(await transport.recordedRequests())
    }

    func testProviderFailureKeepsTheTurnAndDoesNotSubmit() async throws {
        let (model, transport) = makeModel(
            deltasByAttempt: [[]],
            statusCodes: [401],
            responses: [nextResponse(advocate, sequence: 1, startsRound: true)]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("API Key"))
        XCTAssertEqual(model.scheduledTurn?.turnId, advocate.id)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url?.path.hasSuffix("/turns/next") == true)
        XCTAssertTrue(model.room?.messages.isEmpty == true)
    }

    func testRetryReusesTheSamePendingTurnAndSubmitsOnce() async throws {
        let reply = ReplyFixture(
            messageType: "proposal",
            stance: nil,
            claim: "第二次成功了",
            body: "第二次成功了。",
            sequence: 3
        )
        let (model, transport) = makeModel(
            deltasByAttempt: [[], ["第二次成功了。"]],
            statusCodes: [401, 200],
            responses: [
                nextResponse(advocate, sequence: 1, startsRound: true),
                nextResponse(advocate, sequence: 1, startsRound: true),
                completedResponse(advocate, reply: reply),
                roundCompletedResponse(sequence: 4)
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())

        await model.runFirstRound()
        guard case .failed = model.turnState else {
            return XCTFail("expected the first attempt to fail, got \(model.turnState)")
        }
        await model.retryTurn()

        XCTAssertEqual(model.turnState, .roundCompleted(round: 1))
        XCTAssertEqual(model.room?.messages.count, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/messages",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next"
            ]
        )
    }

    func testMissingProviderBlocksBeforeRequestingATurn() async throws {
        let (model, transport) = makeModel(deltasByAttempt: [[]])
        model.present(snapshot())

        await model.runFirstRound()

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("尚未配置"))
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testEmptyReplyAndPartialStreamsAreActionable() async throws {
        let empty = makeModel(
            deltasByAttempt: [[]],
            responses: [nextResponse(advocate, sequence: 1, startsRound: true)]
        )
        enableProvider(on: empty.0)
        empty.0.present(snapshot())
        await empty.0.runFirstRound()
        guard case let .failed(_, emptyMessage, _) = empty.0.turnState else {
            return XCTFail("expected empty reply to fail")
        }
        XCTAssertTrue(emptyMessage.contains("空"))

        let partial = makeModel(
            deltasByAttempt: [["先做一个两周"]],
            errorAfterDeltas: URLError(.networkConnectionLost),
            responses: [nextResponse(advocate, sequence: 1, startsRound: true)]
        )
        enableProvider(on: partial.0)
        partial.0.present(snapshot())
        await partial.0.runFirstRound()
        guard case let .failed(_, networkMessage, text) = partial.0.turnState else {
            return XCTFail("expected partial stream to fail")
        }
        XCTAssertTrue(networkMessage.contains("网络"))
        XCTAssertEqual(text, "先做一个两周")
    }

}

extension RealTurnTests {
    func makeModel(
        deltasByAttempt: [[String]],
        statusCodes: [Int] = [200],
        errorAfterDeltas: Error? = nil,
        responses: [HTTPResponse] = []
    ) -> (AppModel, TurnTransport) {
        let transport = TurnTransport(responses: responses)
        let store = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        let stream = TurnLineStream(
            deltasByAttempt: deltasByAttempt,
            statusCodes: statusCodes,
            errorAfterDeltas: errorAfterDeltas
        )
        lastStream = stream
        let model = AppModel(
            defaults: defaults,
            providerStore: store,
            chatClient: ProviderChatClient(
                streaming: stream
            ),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            )
        )
        return (model, transport)
    }

    func snapshot() -> RoundtableSnapshot {
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

    func enableProvider(on model: AppModel) {
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

    func secondRoundResponses(skepticMessageID: UUID) -> [HTTPResponse] {
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
            claim: "必须先定义停止条件",
            body: "必须先定义停止条件。",
            sequence: 5,
            messageID: skepticMessageID
        )
        let review = ReplyFixture(
            messageType: "challenge",
            stance: "challenge",
            claim: "验证成本仍然被低估",
            body: "我质疑这个观点，因为团队注意力也是成本。",
            sequence: 11,
            roundNumber: 2,
            references: [skepticMessageID],
            challengeTargetAgentID: skeptic.agentID
        )
        return [
            nextResponse(advocate, sequence: 1, startsRound: true),
            completedResponse(advocate, reply: proposal),
            nextResponse(skeptic, sequence: 4),
            completedResponse(skeptic, reply: challenge),
            nextResponse(experience, sequence: 6),
            passResponse(experience, sequence: 7),
            roundTwoNextResponse(),
            completedResponse(advocate, reply: review),
            roundCompletedResponse(sequence: 12, round: 2)
        ]
    }

    private func roundTwoNextResponse() -> HTTPResponse {
        let thinking = event(
            "agent.thinking",
            sequence: 10,
            payload: [
                "turn_id": advocate.id.uuidString,
                "round": 2,
                "agent_id": advocate.agentID.uuidString,
                "agent_name": advocate.name
            ]
        )
        return jsonResponse(
            [
                "round": 2,
                "turn": advocate.wire(round: 2),
                "events": [
                    event(
                        "round.completed",
                        sequence: 8,
                        payload: ["round": 1]
                    ),
                    event(
                        "round.started",
                        sequence: 9,
                        payload: ["round": 2, "max_rounds": 2, "topic": "议题"]
                    ),
                    thinking
                ]
            ],
            statusCode: 200
        )
    }

    private func nextResponse(
        _ turn: TurnFixture,
        sequence: Int,
        startsRound: Bool = false,
        round: Int = 1
    ) -> HTTPResponse {
        var events: [[String: Any]] = []
        if startsRound {
            events.append(
                event(
                    "round.started",
                    sequence: sequence,
                    payload: ["round": round, "max_rounds": 2, "topic": "议题"]
                )
            )
        }
        events.append(
            event(
                "agent.thinking",
                sequence: sequence + (startsRound ? 1 : 0),
                payload: [
                    "turn_id": turn.id.uuidString,
                    "round": round,
                    "agent_id": turn.agentID.uuidString,
                    "agent_name": turn.name
                ]
            )
        )
        return jsonResponse(
            ["round": round, "turn": turn.wire(round: round), "events": events],
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

    private func roundCompletedResponse(sequence: Int, round: Int = 1) -> HTTPResponse {
        jsonResponse(
            [
                "round": round,
                "turn": NSNull(),
                "events": [event("round.completed", sequence: sequence, payload: ["round": round])]
            ],
            statusCode: 200
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

    private func assertFirstRoundRequests(_ requests: [URLRequest]) {
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/messages",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/messages",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/pass",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next"
            ]
        )
        let bodies = requests.compactMap(\.httpBody).compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(
            bodies.compactMap { $0["turn_id"] as? String },
            [advocate.id.uuidString, skeptic.id.uuidString, experience.id.uuidString]
        )
        XCTAssertFalse(
            requests.contains {
                String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("sk-test-turn") == true
            }
        )
    }
}
