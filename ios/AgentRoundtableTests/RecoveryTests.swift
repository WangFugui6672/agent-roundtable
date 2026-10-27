import Foundation
import XCTest

import RoundtableCore

@testable import AgentRoundtable

@MainActor
final class RecoveryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: TurnSecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "roundtable.recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = TurnSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBootstrapRestoresCachedMessagesWhenNetworkIsUnavailable() async throws {
        let store = InMemoryRoomStore()
        let roomID = UUID()
        let snapshot = makeSnapshot(id: roomID, status: .running)
        let model = RoundtableRoomModel()
        model.seed(snapshot, cursor: 0)
        let message = Message(
            id: UUID(),
            roundNumber: 0,
            author: MessageAuthor(type: .user, name: "用户"),
            messageType: .userMessage,
            body: "断网后仍应可读。",
            stance: nil,
            references: [],
            createdAt: Date()
        )
        model.apply(
            EventEnvelope(
                eventId: UUID(),
                roomId: roomID,
                sequence: 1,
                createdAt: Date(),
                eventType: "message.completed",
                payload: .messageCompleted(message)
            )
        )
        try store.save(model.storedState(savedAt: Date()))
        defaults.set(UUID().uuidString, forKey: "roundtable.guestSessionID")

        let app = makeModel(
            store: store,
            transport: FailingTransport(error: URLError(.notConnectedToInternet)),
            socketFactory: CountingSocketFactory()
        )

        await app.bootstrap()

        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.room?.messages.map(\.id), [message.id])
        guard case let .failed(messageText) = app.streamState else {
            return XCTFail("expected an offline state")
        }
        XCTAssertTrue(messageText.contains("离线"))
    }

    func testForegroundDoesNotDuplicateAnActiveConnection() async {
        defaults.set(UUID().uuidString, forKey: "roundtable.guestSessionID")
        let factory = CountingSocketFactory()
        let app = makeModel(
            store: InMemoryRoomStore(),
            transport: ProfilesTransport(),
            socketFactory: factory
        )
        await app.bootstrap()
        app.present(makeSnapshot(id: UUID(), status: .ready))

        app.enterForeground()
        await waitForConnections(1, factory: factory)
        app.enterForeground()
        await Task.yield()
        XCTAssertEqual(factory.connectionCount(), 1)

        app.enterBackground()
        await waitUntil { factory.connectionCount() == 1 }
        app.enterForeground()
        await waitForConnections(2, factory: factory)
        let count = factory.connectionCount()
        app.enterForeground()
        await Task.yield()
        XCTAssertEqual(factory.connectionCount(), count)
        app.enterBackground()
    }

    func testBackgroundCancelsGenerationAndLeavesAStablePauseBoundary() async {
        defaults.set(UUID().uuidString, forKey: "roundtable.guestSessionID")
        let app = makeModel(
            store: InMemoryRoomStore(),
            transport: ProfilesTransport(),
            socketFactory: CountingSocketFactory()
        )
        app.present(makeSnapshot(id: UUID(), status: .ready))
        app.turnState = .thinking(agentID: UUID())
        app.isFirstRoundRunning = true
        app.scheduledTurn = ScheduledTurn(
            turnId: UUID(),
            round: 1,
            roundtableAgentId: UUID(),
            position: 0,
            agentKey: "advocate",
            agentName: "方案派"
        )

        app.enterBackground()

        XCTAssertEqual(app.turnState, .paused)
        XCTAssertFalse(app.isFirstRoundRunning)
        XCTAssertNil(app.scheduledTurn)
        XCTAssertNil(app.generationTask)
        await Task.yield()
    }

    private func makeModel(
        store: InMemoryRoomStore,
        transport: HTTPTransport,
        socketFactory: any RoundtableSocketFactory
    ) -> AppModel {
        let providerStore = ProviderStore(
            secrets: secrets,
            storage: UserDefaultsProviderStorage(defaults: defaults)
        )
        return AppModel(
            defaults: defaults,
            providerStore: providerStore,
            guestSessionStore: AnonymousSessionStore(secrets: secrets),
            api: APIClient(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                transport: transport
            ),
            roomStore: store,
            socketFactory: socketFactory
        )
    }

    private func makeSnapshot(id: UUID, status: RoundtableStatus) -> RoundtableSnapshot {
        RoundtableSnapshot(
            id: id,
            topic: "断线恢复测试",
            status: status,
            mode: "decision",
            maxRounds: 2,
            currentRound: 1,
            lastSequence: 0,
            createdAt: Date(),
            updatedAt: Date(),
            participants: []
        )
    }

    private func waitForConnections(
        _ count: Int,
        factory: CountingSocketFactory,
        timeout: TimeInterval = 2
    ) async {
        await waitUntil(timeout: timeout) {
            factory.connectionCount() >= count
        }
        XCTAssertGreaterThanOrEqual(factory.connectionCount(), count)
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
}

private struct FailingTransport: HTTPTransport {
    let error: Error

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw error
    }
}

private struct ProfilesTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let data = Data("[]".utf8)
        return HTTPResponse(data: data, statusCode: 200)
    }
}

private final class CountingSocketFactory: RoundtableSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func makeSocket(url: URL) -> any RoundtableSocket {
        lock.lock()
        count += 1
        lock.unlock()
        return PassiveSocket()
    }

    func connectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class PassiveSocket: RoundtableSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<EventEnvelope, Error>.Continuation?

    func events() -> AsyncThrowingStream<EventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.clearContinuation()
            }
        }
    }

    func send(_ text: String) async throws {}

    func cancel() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    private func clearContinuation() {
        lock.lock()
        continuation = nil
        lock.unlock()
    }
}
