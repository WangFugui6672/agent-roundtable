import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

private final class ControlSecretStore: SecretStore {
    var values: [String: String] = [:]

    func secret(for account: String) throws -> String? { values[account] }
    func setSecret(_ secret: String, for account: String) throws { values[account] = secret }
    func removeSecret(for account: String) throws { values[account] = nil }
}

private actor ControlTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []

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

    func recordedRequests() -> [URLRequest] { requests }
}

private actor DelayedLineStream: LineStreaming {
    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        StreamingResponse(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                let task = Task {
                    try await Task.sleep(for: .seconds(30))
                    continuation.yield(#"data: {"choices":[{"delta":{"content":"太晚了"}}]}"#)
                    continuation.yield("data: [DONE]")
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        )
    }
}

@MainActor
final class UserControlTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: ControlSecretStore!

    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000101")!
    private let advocateID = UUID(uuidString: "D00D0000-0000-4000-8000-000000000101")!
    private let skepticID = UUID(uuidString: "E00E0000-0000-4000-8000-000000000102")!
    private let experienceID = UUID(uuidString: "F00F0000-0000-4000-8000-000000000103")!
    private var turnID: UUID {
        UUID(uuidString: "A11CE000-0000-4000-8000-000000000101")!
    }

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.user-control.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = ControlSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUserMessageAppliesUserAuthorAndPauseBoundary() async {
        let userEvent = event(
            "message.completed",
            sequence: 1,
            payload: [
                "message": userMessage()
            ]
        )
        let response = commandResponse(
            snapshot(status: .running, currentRound: 1, pausePending: true),
            events: [
                userEvent,
                event(
                    "room.pause_pending",
                    sequence: 2,
                    payload: ["turn_id": turnID.uuidString]
                )
            ]
        )
        let (model, _) = makeModel(responses: [jsonResponse(response, statusCode: 201)])
        model.present(snapshot(status: .running, currentRound: 1))

        await model.sendUserMessage(
            "先补充一个约束：团队只有两个人。",
            mentionedAgentIDs: [experienceID]
        )

        guard let room = model.room else {
            return XCTFail("expected an open room")
        }
        XCTAssertNil(model.controlError)
        XCTAssertEqual(room.messages.count, 1)
        XCTAssertEqual(room.messages[0].author.type, .user)
        XCTAssertEqual(room.messages[0].mentionedAgentIds, [experienceID])
        XCTAssertTrue(room.pausePending)
        XCTAssertEqual(room.status, .running)
    }

    func testResumeStartsExactlyOneAutomaticFlow() async {
        let resume = commandResponse(
            snapshot(status: .running, currentRound: 1),
            events: [
                event(
                    "room.resumed",
                    sequence: 3,
                    payload: ["status": "running"]
                )
            ]
        )
        let noTurn = [
            "round": 1,
            "turn": NSNull(),
            "events": []
        ] as [String: Any]
        let (model, transport) = makeModel(
            responses: [
                jsonResponse(resume, statusCode: 200),
                jsonResponse(noTurn, statusCode: 200)
            ]
        )
        enableProvider(on: model)
        model.present(snapshot(status: .paused, currentRound: 1))

        await model.resumeDiscussion()
        await waitForRequests(2, on: transport)
        await waitUntil { !model.isFirstRoundRunning }

        let requests = await transport.recordedRequests()
        XCTAssertNil(model.controlError)
        XCTAssertEqual(
            requests.filter { $0.url?.path.hasSuffix("/turns/next") == true }.count,
            1
        )
        XCTAssertEqual(model.room?.status, .running)
    }

    func testPausePendingStopsAfterTheCurrentTurnWithoutRequestingAnother() async {
        let next = [
            "round": 1,
            "turn": turnWire(),
            "events": [
                event(
                    "agent.thinking",
                    sequence: 1,
                    payload: [
                        "turn_id": turnID.uuidString,
                        "round": 1,
                        "agent_id": advocateID.uuidString,
                        "agent_name": "方案派"
                    ]
                )
            ]
        ] as [String: Any]
        let completed = event(
            "message.completed",
            sequence: 2,
            payload: [
                "message": agentMessage()
            ]
        )
        let (model, transport) = makeModel(
            responses: [
                jsonResponse(next, statusCode: 200),
                jsonResponse(completed, statusCode: 201)
            ]
        )
        enableProvider(on: model)
        model.present(snapshot(status: .running, currentRound: 1, pausePending: true))

        await model.runFirstRound()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/turns/next",
                "/api/v1/roundtables/\(roomID.uuidString.lowercased())/messages"
            ]
        )
        XCTAssertEqual(model.turnState, .paused)
    }

    func testEndCancelsInFlightProviderAndPreventsFurtherCalls() async {
        let next = [
            "round": 1,
            "turn": turnWire(),
            "events": [
                event(
                    "agent.thinking",
                    sequence: 4,
                    payload: [
                        "turn_id": turnID.uuidString,
                        "round": 1,
                        "agent_id": advocateID.uuidString,
                        "agent_name": "方案派"
                    ]
                )
            ]
        ] as [String: Any]
        let ended = commandResponse(
            snapshot(status: .summarizing, currentRound: 1),
            events: [
                event(
                    "room.ended",
                    sequence: 5,
                    payload: ["status": "summarizing"]
                ),
                event(
                    "summary.started",
                    sequence: 6,
                    payload: ["round": 1]
                )
            ]
        )
        let (model, transport) = makeModel(
            responses: [
                jsonResponse(next, statusCode: 200),
                jsonResponse(ended, statusCode: 200)
            ],
            delayingProvider: true
        )
        enableProvider(on: model)
        model.present(snapshot(status: .running, currentRound: 1))

        model.startGeneration()
        await waitUntil { model.scheduledTurn != nil }
        await model.endDiscussion()
        await waitUntil { !model.isFirstRoundRunning }

        XCTAssertEqual(model.room?.status, .summarizing)
        XCTAssertEqual(model.turnState, .ended)
        XCTAssertNil(model.scheduledTurn)
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/messages") == true })
        XCTAssertTrue(requests.last?.url?.path.hasSuffix("/end") == true)
        model.leaveRoom()
    }
}

private extension UserControlTests {
    private func makeModel(
        responses: [HTTPResponse],
        delayingProvider: Bool = false
    ) -> (AppModel, ControlTransport) {
        let transport = ControlTransport(responses: responses)
        let providerStore = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        let chatClient = ProviderChatClient(
            streaming: delayingProvider ? DelayedLineStream() : ImmediateLineStream()
        )
        let model = AppModel(
            defaults: defaults,
            providerStore: providerStore,
            chatClient: chatClient,
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            )
        )
        return (model, transport)
    }

    private func enableProvider(on model: AppModel) {
        model.saveProvider(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-test-user-control"
            )
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition was not met before timeout")
    }

    private func waitForRequests(
        _ count: Int,
        on transport: ControlTransport,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await transport.recordedRequests().count < count, Date() < deadline {
            await Task.yield()
        }
        let requestCount = await transport.recordedRequests().count
        XCTAssertGreaterThanOrEqual(requestCount, count)
    }

    private func snapshot(
        status: RoundtableStatus,
        currentRound: Int,
        pausePending: Bool = false
    ) -> RoundtableSnapshot {
        RoundtableSnapshot(
            id: roomID,
            topic: "该不该把验证周期压缩到两周？",
            status: status,
            mode: "decision",
            maxRounds: 2,
            currentRound: currentRound,
            lastSequence: 0,
            pausePending: pausePending,
            createdAt: Date(),
            updatedAt: Date(),
            participants: [
                participant(id: advocateID, position: 0, key: "advocate", name: "方案派"),
                participant(id: skepticID, position: 1, key: "skeptic", name: "质疑派"),
                participant(id: experienceID, position: 2, key: "experience", name: "体验派")
            ]
        )
    }

    private func participant(
        id: UUID,
        position: Int,
        key: String,
        name: String
    ) -> Participant {
        Participant(
            id: id,
            position: position,
            state: .waiting,
            agent: AgentProfile(
                id: UUID(),
                key: key,
                name: name,
                tagline: "定位",
                expertise: "专长",
                goal: "目标",
                defaultStance: "立场",
                style: "风格",
                bannedBehaviors: [],
                maxReplyChars: 180
            )
        )
    }

    private func userMessage() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "turn_id": NSNull(),
            "round_number": 1,
            "author": ["type": "user", "name": "用户"],
            "message_type": "user_message",
            "claim": NSNull(),
            "body": "先补充一个约束：团队只有两个人。",
            "stance": NSNull(),
            "references": [],
            "confidence": NSNull(),
            "mentioned_agent_ids": [experienceID.uuidString],
            "created_at": "2026-10-27T01:02:04.000Z"
        ]
    }

    private func agentMessage() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "turn_id": turnID.uuidString,
            "round_number": 1,
            "author": [
                "type": "agent",
                "roundtable_agent_id": advocateID.uuidString,
                "agent_key": "advocate",
                "name": "方案派"
            ],
            "message_type": "proposal",
            "claim": "先做一个两周实验。",
            "body": "先做一个两周实验。",
            "stance": NSNull(),
            "references": [],
            "confidence": 0.6,
            "mentioned_agent_ids": [],
            "created_at": "2026-10-27T01:02:04.000Z"
        ]
    }

    private func turnWire() -> [String: Any] {
        [
            "turn_id": turnID.uuidString,
            "round": 1,
            "roundtable_agent_id": advocateID.uuidString,
            "position": 0,
            "agent_key": "advocate",
            "agent_name": "方案派"
        ]
    }

    private func commandResponse(
        _ snapshot: RoundtableSnapshot,
        events: [[String: Any]]
    ) -> [String: Any] {
        [
            "roundtable": snapshotWire(snapshot),
            "events": events
        ]
    }

    private func snapshotWire(_ snapshot: RoundtableSnapshot) -> [String: Any] {
        [
            "id": snapshot.id.uuidString,
            "topic": snapshot.topic,
            "status": snapshot.status.rawValue,
            "mode": snapshot.mode,
            "max_rounds": snapshot.maxRounds,
            "current_round": snapshot.currentRound,
            "last_sequence": snapshot.lastSequence,
            "pause_pending": snapshot.pausePending ?? false,
            "active_turn": NSNull(),
            "provider": NSNull(),
            "created_at": "2026-10-27T01:02:03.456Z",
            "updated_at": "2026-10-27T01:02:03.456Z",
            "participants": snapshot.participants.map { participant in
                [
                    "id": participant.id.uuidString,
                    "position": participant.position,
                    "state": participant.state.rawValue,
                    "agent": [
                        "id": participant.agent.id.uuidString,
                        "key": participant.agent.key,
                        "name": participant.agent.name,
                        "tagline": participant.agent.tagline,
                        "expertise": participant.agent.expertise,
                        "goal": participant.agent.goal,
                        "default_stance": participant.agent.defaultStance,
                        "style": participant.agent.style,
                        "banned_behaviors": participant.agent.bannedBehaviors,
                        "max_reply_chars": participant.agent.maxReplyChars
                    ] as [String: Any]
                ] as [String: Any]
            }
        ]
    }

    private func event(
        _ type: String,
        sequence: Int,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "event_id": UUID().uuidString,
            "room_id": roomID.uuidString,
            "sequence": sequence,
            "created_at": "2026-10-27T01:02:03.456Z",
            "event_type": type,
            "payload": payload
        ]
    }

    private func jsonResponse(_ object: Any, statusCode: Int) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(data: data, statusCode: statusCode)
    }
}

private actor ImmediateLineStream: LineStreaming {
    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        StreamingResponse(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                continuation.yield(
                    #"data: {"choices":[{"delta":{"content":"先做一个两周实验。"}}]}"#
                )
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
        )
    }
}
