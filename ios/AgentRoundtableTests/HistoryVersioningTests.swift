import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

@MainActor
final class HistoryVersioningTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: HistorySecretStore!
    private let roomID = UUID()
    private let agentID = UUID()
    private let messageID = UUID()

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.history.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = HistorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCachedHistoryOpensMessagesAndScrollContext() async throws {
        let store = InMemoryRoomStore()
        let state = try cachedState()
        try store.save(state)
        let app = makeModel(store: store, transport: HistoryHTTPTransport(responses: []))
        app.reloadCachedHistory()
        let entry = try XCTUnwrap(app.historyEntries.first)
        XCTAssertTrue(entry.isCached)

        await app.openHistory(entry)

        XCTAssertTrue(app.isRoomPresented)
        XCTAssertEqual(app.room?.messages.map(\.id), [messageID])
        XCTAssertEqual(app.room?.lastVisibleMessageID, messageID)
        XCTAssertEqual(app.room?.snapshot?.id, roomID)
    }

    func testDeletingAnonymousSessionClearsCacheButKeepsProviderKey() async throws {
        let store = InMemoryRoomStore()
        try store.save(cachedState())
        let oldSession = UUID()
        try AnonymousSessionStore(secrets: secrets).save(oldSession)
        try ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        ).save(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-keep"
            )
        )
        let app = makeModel(
            store: store,
            transport: HistoryHTTPTransport(
                responses: [HTTPResponse(data: Data(), statusCode: 204)]
            ),
            guestSessionID: oldSession
        )
        app.reloadCachedHistory()

        await app.deleteGuestSession()

        XCTAssertNil(app.guestSessionID)
        XCTAssertNil(app.room)
        XCTAssertTrue(app.historyEntries.isEmpty)
        XCTAssertNil(try AnonymousSessionStore(secrets: secrets).load())
        XCTAssertTrue(try store.loadAll().isEmpty)
        XCTAssertEqual(
            try ProviderStore(
                secrets: secrets,
                storage: UserDefaultsProviderStorage(defaults: defaults)
            ).secret(for: .deepseek),
            "sk-keep"
        )
    }

    func testSessionRotationPersistsTheNewBearerToken() async throws {
        let old = UUID()
        let replacement = UUID()
        try AnonymousSessionStore(secrets: secrets).save(old)
        let response = """
        {"id":"\(replacement.uuidString)","created_at":"2026-10-26T01:02:03.456Z"}
        """
        let app = makeModel(
            store: InMemoryRoomStore(),
            transport: HistoryHTTPTransport(
                responses: [
                    HTTPResponse(data: Data(response.utf8), statusCode: 200)
                ]
            ),
            guestSessionID: old
        )

        await app.rotateGuestSession()

        XCTAssertEqual(app.guestSessionID, replacement)
        XCTAssertEqual(try AnonymousSessionStore(secrets: secrets).load(), replacement)
    }

    func testKeyPointToggleUsesServerResultAndPersists() async throws {
        let messageJSON = FixturesForApp.messageJSON(messageID: messageID, agentID: agentID)
            .replacingOccurrences(
                of: "\"message_type\": \"proposal\",",
                with: "\"message_type\": \"proposal\", \"is_key_point\": true,"
            )
        let app = makeModel(
            store: InMemoryRoomStore(),
            transport: HistoryHTTPTransport(
                responses: [
                    HTTPResponse(data: Data(messageJSON.utf8), statusCode: 200)
                ]
            ),
            guestSessionID: UUID()
        )
        app.present(snapshot())
        try app.repository.apply(messageEnvelope())

        await app.toggleKeyPoint(messageID)

        XCTAssertEqual(app.room?.messages.first?.isKeyPoint, true)
        XCTAssertNil(app.controlError)
        XCTAssertTrue(try app.repository.loadCachedRooms().first?.messages.first?.isKeyPoint == true)
    }

    private func makeModel(
        store: InMemoryRoomStore,
        transport: HistoryHTTPTransport,
        guestSessionID: UUID? = nil
    ) -> AppModel {
        let model = AppModel(
            defaults: defaults,
            providerStore: ProviderStore(
                secrets: secrets,
                storage: UserDefaultsProviderStorage(defaults: defaults)
            ),
            guestSessionStore: AnonymousSessionStore(secrets: secrets),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: guestSessionID
            ),
            roomStore: store,
            socketFactory: HistoryPassiveSocketFactory()
        )
        model.guestSessionID = guestSessionID
        return model
    }

    private func cachedState() throws -> StoredRoomState {
        let model = RoundtableRoomModel()
        model.seed(snapshot(), cursor: 0)
        model.apply(messageEnvelope())
        model.setLastVisibleMessage(messageID)
        return model.storedState(savedAt: Date())
    }

    private func snapshot() -> RoundtableSnapshot {
        RoundtableSnapshot(
            id: roomID,
            topic: "历史恢复",
            status: .running,
            mode: "decision",
            maxRounds: 2,
            currentRound: 1,
            lastSequence: 0,
            createdAt: Date(),
            updatedAt: Date(),
            participants: [
                Participant(
                    id: agentID,
                    position: 0,
                    state: .completed,
                    agent: AgentProfile(
                        id: UUID(),
                        key: "advocate",
                        name: "方案派",
                        tagline: "方案",
                        expertise: "产品",
                        goal: "推进",
                        defaultStance: "支持",
                        style: "直接",
                        bannedBehaviors: [],
                        maxReplyChars: 180
                    )
                )
            ]
        )
    }

    private func messageEnvelope() -> EventEnvelope {
        EventEnvelope(
            eventId: UUID(),
            roomId: roomID,
            sequence: 1,
            createdAt: Date(),
            eventType: "message.completed",
            payload: .messageCompleted(
                Message(
                    id: messageID,
                    turnId: UUID(),
                    roundNumber: 1,
                    author: MessageAuthor(
                        roundtableAgentId: agentID,
                        agentKey: "advocate",
                        name: "方案派"
                    ),
                    messageType: .proposal,
                    claim: "缓存观点",
                    body: "打开历史时必须恢复这条完整消息。",
                    stance: nil,
                    references: [],
                    createdAt: Date()
                )
            )
        )
    }
}

private enum FixturesForApp {
    static func messageJSON(messageID: UUID, agentID: UUID) -> String {
        """
        {
          "id": "\(messageID.uuidString)",
          "turn_id": "\(UUID().uuidString)",
          "round_number": 1,
          "author": {
            "type": "agent",
            "roundtable_agent_id": "\(agentID.uuidString)",
            "agent_key": "advocate",
            "name": "方案派"
          },
          "message_type": "proposal",
          "claim": "缓存观点",
          "body": "打开历史时必须恢复这条完整消息。",
          "stance": null,
          "references": [],
          "challenge_target_agent_id": null,
          "confidence": 0.6,
          "mentioned_agent_ids": [],
          "created_at": "2026-10-26T01:02:03.456Z"
        }
        """
    }
}

private final class HistorySecretStore: SecretStore {
    var values: [String: String] = [:]

    func secret(for account: String) throws -> String? { values[account] }
    func setSecret(_ secret: String, for account: String) throws { values[account] = secret }
    func removeSecret(for account: String) throws { values[account] = nil }
}

private actor HistoryHTTPTransport: HTTPTransport {
    private var responses: [HTTPResponse]

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else {
            throw URLError(.notConnectedToInternet)
        }
        return responses.removeFirst()
    }
}

private final class HistoryPassiveSocketFactory: RoundtableSocketFactory, @unchecked Sendable {
    func makeSocket(url: URL) -> any RoundtableSocket {
        HistoryPassiveSocket()
    }
}

private final class HistoryPassiveSocket: RoundtableSocket, @unchecked Sendable {
    func events() -> AsyncThrowingStream<EventEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }

    func send(_ text: String) async throws {}
    func cancel() {}
}
