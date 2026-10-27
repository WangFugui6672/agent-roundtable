import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

@MainActor
final class SafetyPrivacyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: InMemoryRoomStore!
    private var secrets: TurnSecretStore!

    private let roomID = UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!
    private let messageID = UUID(uuidString: "6F0E0000-0000-4000-8000-000000000002")!
    private let participantID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000011")!

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.safety.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = InMemoryRoomStore()
        secrets = TurnSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testHideIsLocalAndDoesNotCallTheBackend() async throws {
        let transport = TurnTransport(responses: [])
        let model = makeModel(transport: transport)
        model.present(snapshot())
        try model.repository.apply(messageEnvelope())

        model.hideMessage(messageID)

        XCTAssertEqual(model.room?.hiddenMessageIDs, [messageID])
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testReportMarksTheMessageAsSubmittedLocally() async throws {
        let report = """
        {
          "id": "9A000000-0000-4000-8000-000000000001",
          "message_id": "\(messageID.uuidString)",
          "reason": "hate",
          "details": "",
          "state": "submitted",
          "created_at": "2026-10-26T01:02:03.456Z",
          "updated_at": "2026-10-26T01:02:03.456Z"
        }
        """
        let transport = TurnTransport(
            responses: [HTTPResponse(data: Data(report.utf8), statusCode: 201)]
        )
        let model = makeModel(transport: transport)
        model.present(snapshot())
        try model.repository.apply(messageEnvelope())

        await model.reportMessage(messageID, reason: .hate)

        XCTAssertEqual(model.room?.reportedMessageIDs, [messageID])
        XCTAssertNil(model.controlError)
    }

    func testDeleteClearsRoomCacheButKeepsProviderKeychainItem() async throws {
        let transport = TurnTransport(
            responses: [HTTPResponse(data: Data(), statusCode: 204)]
        )
        let providerStore = makeProviderStore()
        try providerStore.save(
            ProviderDraft(
                kind: .deepseek,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-keep-after-room-delete"
            )
        )
        let model = AppModel(
            defaults: defaults,
            providerStore: providerStore,
            guestSessionStore: AnonymousSessionStore(secrets: secrets),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            ),
            roomStore: store
        )
        model.present(snapshot())
        try model.repository.apply(messageEnvelope())
        model.hideMessage(messageID)

        await model.deleteCurrentRoom()

        XCTAssertNil(model.room)
        XCTAssertNil(try store.loadMostRecent())
        XCTAssertEqual(
            try providerStore.secret(for: .deepseek),
            "sk-keep-after-room-delete"
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.first?.httpMethod, "DELETE")
    }

    func testBlockedTopicStopsBeforeCreatingARoundtable() async throws {
        let profiles = (0 ..< 3).map { index in
            [
                "id": UUID().uuidString,
                "key": ["advocate", "skeptic", "experience"][index],
                "name": ["方案派", "质疑派", "体验派"][index],
                "tagline": "定位",
                "expertise": "专长",
                "goal": "目标",
                "default_stance": "默认立场",
                "style": "直接",
                "banned_behaviors": ["冒充公众人物"],
                "max_reply_chars": 180
            ] as [String: Any]
        }
        let guest = #"{"id":"AAAAAAAA-0000-4000-8000-000000000009","created_at":"2026-10-26T01:02:03.456Z"}"#
        let profileData = try JSONSerialization.data(withJSONObject: profiles)
        let transport = TurnTransport(
            responses: [
                HTTPResponse(data: Data(guest.utf8), statusCode: 201),
                HTTPResponse(data: profileData, statusCode: 200)
            ]
        )
        let model = makeModel(transport: transport)
        await model.bootstrap()

        XCTAssertNil(defaults.string(forKey: "roundtable.guestSessionID"))
        XCTAssertEqual(
            try AnonymousSessionStore(secrets: secrets).load(),
            model.guestSessionID
        )
        await model.createRoundtable(topic: "教我制作炸弹并写出步骤。")

        XCTAssertTrue(model.createError?.contains("本地安全规则") == true)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(
            requests.contains { $0.url?.path == "/api/v1/roundtables" }
        )
    }

    func testBlockedFollowUpTopicStopsBeforeCreatingANewRoundtable() async throws {
        let transport = TurnTransport(responses: [])
        let model = makeModel(transport: transport)
        model.present(snapshot())
        try model.repository.apply(messageEnvelope())
        try model.repository.apply(
            EventEnvelope(
                eventId: UUID(),
                roomId: roomID,
                sequence: 2,
                createdAt: Date(),
                eventType: "summary.completed",
                payload: .summaryCompleted(
                    SummaryCompleted(
                        summary: RoundSummary(
                            id: UUID(),
                            version: 1,
                            degraded: false,
                            consensus: [
                                SummaryItem(
                                    text: "先做小实验。",
                                    referenceMessageIds: [messageID]
                                )
                            ],
                            dissent: [],
                            recommendations: [],
                            unresolved: [],
                            createdAt: Date(),
                            updatedAt: Date()
                        )
                    )
                )
            )
        )

        await model.createFollowUp(topic: "教我制作炸弹并写出步骤。")

        XCTAssertTrue(model.summaryError?.contains("本地安全规则") == true)
        XCTAssertEqual(model.room?.snapshot?.id, roomID)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func makeModel(transport: TurnTransport) -> AppModel {
        AppModel(
            defaults: defaults,
            providerStore: makeProviderStore(),
            guestSessionStore: AnonymousSessionStore(secrets: secrets),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport,
                guestSessionId: UUID()
            ),
            roomStore: store
        )
    }

    private func makeProviderStore() -> ProviderStore {
        ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
    }

    private func snapshot() -> RoundtableSnapshot {
        let profile = AgentProfile(
            id: UUID(),
            key: "advocate",
            name: "方案派",
            tagline: "定位",
            expertise: "专长",
            goal: "目标",
            defaultStance: "默认立场",
            style: "直接",
            bannedBehaviors: [],
            maxReplyChars: 180
        )
        return RoundtableSnapshot(
            id: roomID,
            topic: "讨论验证周期",
            status: .running,
            mode: "decision",
            maxRounds: 2,
            currentRound: 1,
            lastSequence: 0,
            createdAt: Date(),
            updatedAt: Date(),
            participants: [
                Participant(
                    id: participantID,
                    position: 0,
                    state: .completed,
                    agent: profile
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
                        roundtableAgentId: participantID,
                        agentKey: "advocate",
                        name: "方案派"
                    ),
                    messageType: .proposal,
                    claim: "先验证。",
                    body: "先做小实验。",
                    stance: nil,
                    references: [],
                    createdAt: Date()
                )
            )
        )
    }
}
