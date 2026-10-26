import Foundation

public enum StreamError: Error, Equatable {
    case notConnected
}

/// Thin wrapper around `URLSessionWebSocketTask`.
///
/// The stream is intentionally dumb: it decodes `EventEnvelope`s and yields
/// them; all state lives in ``RoundtableRoomModel``.
public final class RoundtableStream: @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
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
            URLQueryItem(name: "cursor", value: String(cursor)),
        ]
        return components.url
    }

    public func events() -> AsyncThrowingStream<EventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let socket = session.webSocketTask(with: url)
            lock.lock()
            self.socket = socket
            lock.unlock()
            socket.resume()

            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
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
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Sends the mock-only command documented in docs/protocol.md 3.5.
    public func runMockRound() async throws {
        let socket = lock.withLock { self.socket }
        guard let socket else { throw StreamError.notConnected }
        try await socket.send(.string(#"{"event_type":"mock.run"}"#))
    }

    public func close() {
        let socket = lock.withLock {
            let current = self.socket
            self.socket = nil
            return current
        }
        socket?.cancel(with: .goingAway, reason: nil)
    }
}
