import Foundation
import XCTest

@testable import RoundtableCore

final class RoundtableStreamTests: XCTestCase {
    func testReconnectUsesLastProcessedCursorAndStopsOnDemand() async throws {
        let firstEvent = try EventEnvelope.decode(
            from: Fixtures.envelope(
                eventType: "future.thing",
                sequence: 2,
                payload: "{\"x\": 2}"
            )
        )
        let joined = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        let factory = ScriptedSocketFactory(
            scripts: [
                .events([firstEvent]),
                .events([joined])
            ]
        )
        let stream = RoundtableStream(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            roomID: Fixtures.roomID,
            guestSessionID: UUID(),
            cursor: 1,
            socketFactory: factory,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: 0,
                multiplier: 1,
                maxDelay: 0,
                maxAttempts: nil
            ),
            sleep: { _ in }
        )
        let events = stream.events()
        var iterator = events.makeAsyncIterator()

        var receivedFirstEvent = false
        while let event = try await iterator.next() {
            if case let .envelope(envelope) = event, envelope.eventId == firstEvent.eventId {
                receivedFirstEvent = true
                stream.confirmProcessed(cursor: 2)
                break
            }
        }
        XCTAssertTrue(receivedFirstEvent)

        let deadline = Date().addingTimeInterval(2)
        while factory.requestedURLs().count < 2, Date() < deadline {
            await Task.yield()
        }
        let urls = factory.requestedURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 2)
        XCTAssertEqual(cursor(in: urls[0]), 1)
        XCTAssertEqual(cursor(in: urls[1]), 2)

        stream.close()
        try await Task.sleep(for: .milliseconds(20))
        let connectionsAfterClose = factory.requestedURLs().count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(factory.requestedURLs().count, connectionsAfterClose)
    }

    func testExpiredCursorCanResetToTheAuthoritativeSnapshotSequence() async throws {
        let baseJoin = try EventEnvelope.decode(from: Fixtures.joinedEnvelope)
        guard case let .joined(base) = baseJoin.payload else {
            return XCTFail("expected a joined payload")
        }
        let snapshot = RoundtableSnapshot(
            id: base.roundtable.id,
            topic: base.roundtable.topic,
            status: .running,
            mode: base.roundtable.mode,
            maxRounds: base.roundtable.maxRounds,
            currentRound: 1,
            lastSequence: 20,
            createdAt: base.roundtable.createdAt,
            updatedAt: base.roundtable.updatedAt,
            participants: base.roundtable.participants
        )
        let expiredJoin = EventEnvelope(
            eventId: UUID(),
            roomId: Fixtures.roomID,
            sequence: 0,
            createdAt: Date(),
            eventType: "room.joined",
            payload: .joined(
                JoinedRoom(
                    roundtable: snapshot,
                    messages: [],
                    replay: ReplayMetadata(
                        requestedCursor: 100,
                        oldestSequence: 12,
                        latestSequence: 20,
                        windowDays: 90,
                        cursorExpired: true
                    )
                )
            )
        )
        let factory = ScriptedSocketFactory(
            scripts: [
                .events([expiredJoin]),
                .events([])
            ]
        )
        let stream = RoundtableStream(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            roomID: Fixtures.roomID,
            guestSessionID: UUID(),
            cursor: 100,
            socketFactory: factory,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: 0,
                multiplier: 1,
                maxDelay: 0,
                maxAttempts: nil
            ),
            sleep: { _ in }
        )
        var iterator = stream.events().makeAsyncIterator()

        while let event = try await iterator.next() {
            if case let .envelope(envelope) = event,
               envelope.eventId == expiredJoin.eventId {
                stream.confirmProcessed(cursor: 20, resetCursor: true)
                break
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while factory.requestedURLs().count < 2, Date() < deadline {
            await Task.yield()
        }

        let urls = factory.requestedURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 2)
        XCTAssertEqual(cursor(in: urls[0]), 100)
        XCTAssertEqual(cursor(in: urls[1]), 20)
        stream.close()
    }

    private func cursor(in url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cursor" })?
            .value
            .flatMap(Int.init)
    }
}

private final class ScriptedSocketFactory: RoundtableSocketFactory, @unchecked Sendable {
    enum Script {
        case events([EventEnvelope])
        case failure(Error)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var urls: [URL] = []

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func makeSocket(url: URL) -> any RoundtableSocket {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
        let script = scripts.isEmpty ? .events([]) : scripts.removeFirst()
        return ScriptedSocket(script: script)
    }

    func requestedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private final class ScriptedSocket: RoundtableSocket, @unchecked Sendable {
    private let script: ScriptedSocketFactory.Script

    init(script: ScriptedSocketFactory.Script) {
        self.script = script
    }

    func events() -> AsyncThrowingStream<EventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            switch script {
            case let .events(events):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }

    func send(_ text: String) async throws {}

    func cancel() {}
}
