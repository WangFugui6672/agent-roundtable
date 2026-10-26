import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

private final class TurnSecretStore: SecretStore {
    var values: [String: String] = [:]

    func secret(for account: String) throws -> String? { values[account] }
    func setSecret(_ secret: String, for account: String) throws { values[account] = secret }
    func removeSecret(for account: String) throws { values[account] = nil }
}

private actor TurnLineStream: LineStreaming {
    private let statusCodes: [Int]
    private let deltas: [String]
    private let errorAfterDeltas: Error?
    private var attempt = 0

    init(
        statusCode: Int = 200,
        deltas: [String],
        statusCodes: [Int]? = nil,
        errorAfterDeltas: Error? = nil
    ) {
        self.statusCodes = statusCodes ?? [statusCode]
        self.deltas = deltas
        self.errorAfterDeltas = errorAfterDeltas
    }

    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        let status = statusCodes[min(attempt, statusCodes.count - 1)]
        attempt += 1
        var lines = deltas.map { #"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"# }
        if errorAfterDeltas == nil {
            lines.append("data: [DONE]")
        }
        let failure = errorAfterDeltas
        return StreamingResponse(
            statusCode: status,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish(throwing: failure)
            }
        )
    }
}

private actor TurnTransport: HTTPTransport {
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

@MainActor
final class RealTurnTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: TurnSecretStore!

    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    private let agentID = UUID(uuidString: "D00D0000-0000-4000-8000-000000000003")!

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

    private func makeModel(
        deltas: [String] = ["先做一个两周实验。"],
        statusCode: Int = 200,
        statusCodes: [Int]? = nil,
        errorAfterDeltas: Error? = nil,
        responses: [HTTPResponse]? = nil
    ) -> (AppModel, TurnTransport) {
        let transport = TurnTransport(responses: responses ?? [])
        let store = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        let model = AppModel(
            defaults: defaults,
            providerStore: store,
            chatClient: ProviderChatClient(
                streaming: TurnLineStream(
                    statusCode: statusCode,
                    deltas: deltas,
                    statusCodes: statusCodes,
                    errorAfterDeltas: errorAfterDeltas
                )
            ),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            )
        )
        return (model, transport)
    }

    private func snapshot() -> RoundtableSnapshot {
        func profile(key: String, name: String, stance: String) -> AgentProfile {
            AgentProfile(
                id: UUID(),
                key: key,
                name: name,
                tagline: "定位",
                expertise: "专长",
                goal: "目标",
                defaultStance: stance,
                style: "直接",
                bannedBehaviors: [],
                maxReplyChars: 180
            )
        }
        let participants = [
            Participant(
                id: agentID,
                position: 0,
                state: .waiting,
                agent: profile(key: "advocate", name: "方案派", stance: "倾向推进")
            ),
            Participant(
                id: UUID(),
                position: 1,
                state: .waiting,
                agent: profile(key: "skeptic", name: "质疑派", stance: "倾向怀疑")
            ),
            Participant(
                id: UUID(),
                position: 2,
                state: .waiting,
                agent: profile(key: "experience", name: "体验派", stance: "用户视角")
            )
        ]
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

    private func envelopeJSON(claim: String, body: String) -> String {
        """
        {
          "event_id": "0F9A0000-0000-4000-8000-000000000002",
          "room_id": "\(roomID.uuidString)",
          "sequence": 1,
          "created_at": "2026-10-26T01:02:03.456Z",
          "event_type": "message.completed",
          "payload": {
            "message": {
              "id": "6F0E0000-0000-4000-8000-000000000004",
              "author": {
                "roundtable_agent_id": "\(agentID.uuidString)",
                "agent_key": "advocate",
                "name": "方案派"
              },
              "message_type": "proposal",
              "claim": "\(claim)",
              "body": "\(body)",
              "stance": null,
              "references": [],
              "confidence": 0.6,
              "created_at": "2026-10-26T01:02:04.000Z"
            }
          }
        }
        """
    }

    func testRealTurnStreamsThenSubmitsStructuredMessage() async throws {
        let (model, transport) = makeModel(
            responses: [
                .init(
                    data: Data(envelopeJSON(claim: "先做一个两周实验", body: "先做一个两周实验。").utf8),
                    statusCode: 201
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)

        XCTAssertEqual(model.turnState, .completed(agentID: agentID))
        XCTAssertEqual(model.room?.messages.count, 1)
        XCTAssertEqual(model.room?.messages.first?.claim, "先做一个两周实验")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.path,
            "/api/v1/roundtables/\(roomID.uuidString)/messages"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["message_type"] as? String, "proposal")
        XCTAssertEqual(json["roundtable_agent_id"] as? String, agentID.uuidString)
        XCTAssertEqual(json["claim"] as? String, "先做一个两周实验")
        XCTAssertNil(json["api_key"])
        XCTAssertFalse(
            (String(data: body, encoding: .utf8) ?? "").contains("sk-test-turn"),
            "API key must never be part of the backend request"
        )
    }

    func testProviderFailureIsShownWithoutSubmitting() async throws {
        let (model, transport) = makeModel(deltas: [], statusCode: 401)
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("API Key"))
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty, "must not submit anything after a provider error")
        XCTAssertTrue(model.room?.messages.isEmpty == true)
    }

    func testMissingProviderBlocksTheTurn() async throws {
        let (model, _) = makeModel()
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("尚未配置"))
    }

    func testEmptyReplyIsRejected() async throws {
        let (model, transport) = makeModel(deltas: [])
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)

        guard case let .failed(_, message, _) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("空"))
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPartialDraftIsKeptWhenTheStreamBreaks() async throws {
        let (model, transport) = makeModel(
            deltas: ["先做一个两周"],
            errorAfterDeltas: URLError(.networkConnectionLost)
        )
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)

        guard case let .failed(_, message, partial) = model.turnState else {
            return XCTFail("expected failed, got \(model.turnState)")
        }
        XCTAssertTrue(message.contains("网络"))
        XCTAssertEqual(partial, "先做一个两周")
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRetryRunsTheTurnAgain() async throws {
        let (model, transport) = makeModel(
            deltas: ["第二次成功了。"],
            statusCodes: [401, 200],
            responses: [
                .init(
                    data: Data(envelopeJSON(claim: "第二次成功了", body: "第二次成功了。").utf8),
                    statusCode: 201
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)

        await model.runRealTurn(participant: participant)
        guard case .failed = model.turnState else {
            return XCTFail("expected the first attempt to fail, got \(model.turnState)")
        }

        await model.retryTurn()

        XCTAssertEqual(model.turnState, .completed(agentID: agentID))
        XCTAssertEqual(model.room?.messages.count, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1, "only the successful attempt submits")
    }

    func testCompletedStateCanBeDismissed() async throws {
        let (model, _) = makeModel(
            responses: [
                .init(
                    data: Data(envelopeJSON(claim: "完成", body: "完成。").utf8),
                    statusCode: 201
                )
            ]
        )
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)
        await model.runRealTurn(participant: participant)

        model.dismissTurnError()

        XCTAssertEqual(model.turnState, .idle)
    }

    func testDismissClearsFailure() async throws {
        let (model, _) = makeModel(deltas: [], statusCode: 500)
        enableProvider(on: model)
        model.present(snapshot())
        let participant = try XCTUnwrap(model.room?.participants.first)
        await model.runRealTurn(participant: participant)
        XCTAssertTrue(model.turnState.isBusy == false)

        model.dismissTurnError()

        XCTAssertEqual(model.turnState, .idle)
    }
}
