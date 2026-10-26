import Foundation

public enum StreamError: Error, Equatable {
    case notConnected
    case invalidURL
    case disconnected(String)
}

public struct ReconnectPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval
    public let maxAttempts: Int?

    public init(
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 5,
        maxAttempts: Int? = nil
    ) {
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
        self.maxAttempts = maxAttempts
    }

    func delay(afterFailureAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        return min(maxDelay, initialDelay * pow(multiplier, Double(exponent)))
    }
}

public enum RoundtableConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected(String?)
    case waitingToReconnect(attempt: Int, delaySeconds: TimeInterval)
}

public enum RoundtableStreamEvent: Equatable, Sendable {
    case connection(RoundtableConnectionState)
    case envelope(EventEnvelope)
}

public protocol RoundtableSocket: AnyObject, Sendable {
    func events() -> AsyncThrowingStream<EventEnvelope, Error>
    func send(_ text: String) async throws
    func cancel()
}

public protocol RoundtableSocketFactory: Sendable {
    func makeSocket(url: URL) -> any RoundtableSocket
}

public struct URLSessionSocketFactory: RoundtableSocketFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func makeSocket(url: URL) -> any RoundtableSocket {
        URLSessionRoundtableSocket(url: url, session: session)
    }
}

private final class URLSessionRoundtableSocket: RoundtableSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
    }

    func events() -> AsyncThrowingStream<EventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            task.resume()
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let envelope: EventEnvelope
                        switch message {
                        case let .string(text):
                            envelope = try EventEnvelope.decode(from: Data(text.utf8))
                        case let .data(data):
                            envelope = try EventEnvelope.decode(from: data)
                        @unknown default:
                            continue
                        }
                        continuation.yield(envelope)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                self.task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Reconnecting event stream whose cursor advances after local projection.
public final class RoundtableStream: @unchecked Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let baseURL: URL
    private let roomID: UUID
    private let guestSessionID: UUID
    private let socketFactory: any RoundtableSocketFactory
    private let reconnectPolicy: ReconnectPolicy
    private let sleep: Sleep
    private let lock = NSLock()

    private var cursor: Int
    private var socket: (any RoundtableSocket)?
    private var loopTask: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var acknowledgement: CheckedContinuation<Void, Never>?

    public init(
        baseURL: URL,
        roomID: UUID,
        guestSessionID: UUID,
        cursor: Int,
        socketFactory: any RoundtableSocketFactory = URLSessionSocketFactory(),
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.baseURL = baseURL
        self.roomID = roomID
        self.guestSessionID = guestSessionID
        self.cursor = max(0, cursor)
        self.socketFactory = socketFactory
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
    }

    public static func makeURL(
        baseURL: URL,
        roomID: UUID,
        guestSessionID: UUID,
        cursor: Int
    ) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/v1/roundtables/\(roomID.uuidString)/"
        components.queryItems = [
            URLQueryItem(name: "guest_session", value: guestSessionID.uuidString),
            URLQueryItem(name: "cursor", value: String(max(0, cursor)))
        ]
        return components.url
    }

    public func events() -> AsyncThrowingStream<RoundtableStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let canStart = lock.withLock {
                guard !started else { return false }
                started = true
                stopped = false
                return true
            }
            guard canStart else {
                continuation.finish(throwing: StreamError.disconnected("事件流已经开始。"))
                return
            }

            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.run(continuation: continuation)
            }
            lock.withLock {
                loopTask = task
            }
            continuation.onTermination = { [weak self] _ in
                self?.terminateFromConsumer()
            }
        }
    }

    public func confirmProcessed(cursor sequence: Int, resetCursor: Bool = false) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            cursor = resetCursor ? max(0, sequence) : max(cursor, sequence)
            let continuation = acknowledgement
            acknowledgement = nil
            return continuation
        }
        continuation?.resume()
    }

    public func runMockRound() async throws {
        let current = lock.withLock { socket }
        guard let current else { throw StreamError.notConnected }
        try await current.send(#"{"event_type":"mock.run"}"#)
    }

    public func close() {
        let task = lock.withLock {
            stopped = true
            let task = loopTask
            loopTask = nil
            return task
        }
        task?.cancel()
        resumeAcknowledgement()
        stopCurrentConnection()
    }

    private func run(
        continuation: AsyncThrowingStream<RoundtableStreamEvent, Error>.Continuation
    ) async {
        var attemptedReconnect = false
        var retryAttempt = 0
        var lastError: Error = StreamError.disconnected("连接已断开。")

        while !Task.isCancelled, !isStopped {
            if attemptedReconnect {
                guard await waitBeforeReconnect(
                    attempt: retryAttempt,
                    continuation: continuation
                ) else { break }
            }
            guard !Task.isCancelled, !isStopped else { break }
            guard let socket = openSocket(continuation: continuation) else {
                return
            }

            let outcome = await receive(
                from: socket,
                continuation: continuation
            )
            clearSocket(socket)
            if outcome.cancelled {
                break
            }
            if let error = outcome.error {
                lastError = error
                continuation.yield(.connection(.disconnected(error.localizedDescription)))
            } else {
                lastError = StreamError.disconnected("连接已断开。")
                continuation.yield(.connection(.disconnected("连接已断开。")))
            }
            retryAttempt = outcome.connected ? 1 : retryAttempt + 1
            if let maxAttempts = reconnectPolicy.maxAttempts,
               retryAttempt > maxAttempts {
                continuation.finish(throwing: lastError)
                return
            }
            attemptedReconnect = true
        }
        continuation.finish()
    }

    private func waitBeforeReconnect(
        attempt: Int,
        continuation: AsyncThrowingStream<RoundtableStreamEvent, Error>.Continuation
    ) async -> Bool {
        let delay = reconnectPolicy.delay(afterFailureAttempt: attempt)
        continuation.yield(
            .connection(
                .waitingToReconnect(attempt: attempt, delaySeconds: delay)
            )
        )
        do {
            try await sleep(delay)
            return true
        } catch {
            return false
        }
    }

    private func openSocket(
        continuation: AsyncThrowingStream<RoundtableStreamEvent, Error>.Continuation
    ) -> (any RoundtableSocket)? {
        guard let url = Self.makeURL(
            baseURL: baseURL,
            roomID: roomID,
            guestSessionID: guestSessionID,
            cursor: currentCursor
        ) else {
            continuation.finish(throwing: StreamError.invalidURL)
            return nil
        }
        continuation.yield(.connection(.connecting))
        let socket = socketFactory.makeSocket(url: url)
        setSocket(socket)
        return socket
    }

    private func receive(
        from socket: any RoundtableSocket,
        continuation: AsyncThrowingStream<RoundtableStreamEvent, Error>.Continuation
    ) async -> AttemptOutcome {
        var connected = false
        do {
            for try await envelope in socket.events() {
                guard !Task.isCancelled, !isStopped else {
                    return AttemptOutcome(cancelled: true)
                }
                if !connected {
                    connected = true
                    continuation.yield(.connection(.connected))
                }
                continuation.yield(.envelope(envelope))
                await waitForAcknowledgement()
            }
            return AttemptOutcome(connected: connected)
        } catch is CancellationError {
            return AttemptOutcome(cancelled: true)
        } catch {
            guard !Task.isCancelled, !isStopped else {
                return AttemptOutcome(cancelled: true)
            }
            return AttemptOutcome(connected: connected, error: error)
        }
    }

    private var currentCursor: Int {
        lock.withLock { cursor }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func waitForAcknowledgement() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if stopped {
                    continuation.resume()
                } else {
                    acknowledgement = continuation
                }
            }
        }
    }

    private func resumeAcknowledgement() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = acknowledgement
            acknowledgement = nil
            return continuation
        }
        continuation?.resume()
    }

    private func terminateFromConsumer() {
        let task = lock.withLock {
            stopped = true
            let task = loopTask
            loopTask = nil
            return task
        }
        task?.cancel()
        resumeAcknowledgement()
        stopCurrentConnection()
    }

    private func setSocket(_ newSocket: any RoundtableSocket) {
        lock.withLock {
            socket = newSocket
        }
    }

    private func clearSocket(_ closingSocket: any RoundtableSocket) {
        let shouldClear = lock.withLock { () -> Bool in
            guard socket === closingSocket else { return false }
            socket = nil
            return true
        }
        if shouldClear {
            closingSocket.cancel()
        }
    }

    private func stopCurrentConnection() {
        let current = lock.withLock {
            let value = socket
            socket = nil
            return value
        }
        current?.cancel()
    }
}

private struct AttemptOutcome {
    let connected: Bool
    let error: Error?
    let cancelled: Bool

    init(connected: Bool = false, error: Error? = nil, cancelled: Bool = false) {
        self.connected = connected
        self.error = error
        self.cancelled = cancelled
    }
}
