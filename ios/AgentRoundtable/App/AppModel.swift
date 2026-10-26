import Foundation
import Observation
import RoundtableCore

/// App-level orchestration: session bootstrap, roundtable creation, and the
/// WebSocket lifecycle. All UI state lives here or in ``RoundtableRoomModel``.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum StreamState: Equatable {
        case idle
        case connecting
        case connected
        case closed
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var profiles: [AgentProfile] = []
    private(set) var selectedProfileIDs: [UUID] = []
    private(set) var room: RoundtableRoomModel?
    private(set) var streamState: StreamState = .idle
    private(set) var isCreating = false
    private(set) var isMockRunning = false
    private(set) var createError: String?

    private var api: APIClient
    private var guestSessionID: UUID?
    private var stream: RoundtableStream?
    private var streamTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private static let sessionKey = "roundtable.guestSessionID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.api = APIClient(baseURL: Self.defaultBaseURL)
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        phase = .loading
        do {
            try await loadInitialState()
        } catch let error as APIError where error.code == "guest_session_required" {
            // The stored session can disappear after a database reset or the
            // retention window: drop it and register a fresh one.
            resetGuestSession()
            do {
                try await loadInitialState()
            } catch {
                phase = .failed(Self.message(for: error))
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func loadInitialState() async throws {
        let sessionID = try await ensureGuestSession()
        guestSessionID = sessionID
        api = api.withGuestSession(sessionID)

        let profiles = try await api.fetchAgentProfiles()
        self.profiles = profiles
        if selectedProfileIDs.isEmpty {
            selectedProfileIDs = profiles.map(\.id)
        }
        phase = .ready
    }

    private func resetGuestSession() {
        defaults.removeObject(forKey: Self.sessionKey)
        guestSessionID = nil
        api = api.withGuestSession(nil)
    }

    private func ensureGuestSession() async throws -> UUID {
        if let raw = defaults.string(forKey: Self.sessionKey),
           let stored = UUID(uuidString: raw) {
            return stored
        }
        let session = try await api.createGuestSession()
        defaults.set(session.id.uuidString, forKey: Self.sessionKey)
        return session.id
    }

    // MARK: - Create

    var canStart: Bool {
        guard !isCreating, selectedProfileIDs.count == 3, phase == .ready else { return false }
        return true
    }

    func isSelected(_ profile: AgentProfile) -> Bool {
        selectedProfileIDs.contains(profile.id)
    }

    func toggleSelection(_ profile: AgentProfile) {
        if let index = selectedProfileIDs.firstIndex(of: profile.id) {
            selectedProfileIDs.remove(at: index)
        } else {
            selectedProfileIDs.append(profile.id)
        }
    }

    func createRoundtable(topic: String) async {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, selectedProfileIDs.count == 3, !isCreating else { return }

        isCreating = true
        createError = nil
        defer { isCreating = false }

        do {
            let snapshot = try await api.createRoundtable(
                topic: trimmed,
                agentProfileIds: selectedProfileIDs
            )
            open(snapshot)
        } catch {
            createError = Self.message(for: error)
        }
    }

    // MARK: - Room

    private func open(_ snapshot: RoundtableSnapshot) {
        let room = RoundtableRoomModel()
        room.seed(snapshot)
        self.room = room
        connect(roomID: snapshot.id, cursor: snapshot.lastSequence)
    }

    private func connect(roomID: UUID, cursor: Int) {
        streamTask?.cancel()
        stream?.close()

        guard let guestSessionID,
              let url = RoundtableStream.makeURL(
                  baseURL: api.baseURL,
                  roomID: roomID,
                  guestSessionID: guestSessionID,
                  cursor: cursor
              )
        else {
            streamState = .failed("无法构造 WebSocket 地址。")
            return
        }

        let stream = RoundtableStream(url: url)
        self.stream = stream
        streamState = .connecting

        streamTask = Task { [weak self] in
            do {
                for try await event in stream.events() {
                    guard let self else { return }
                    self.room?.apply(event)
                    if case .joined = event.payload {
                        self.streamState = .connected
                    }
                }
                self?.streamState = .closed
            } catch {
                self?.streamState = .failed(Self.message(for: error))
            }
        }
    }

    func runMockRound() async {
        guard let stream, !isMockRunning else { return }
        isMockRunning = true
        defer { isMockRunning = false }
        do {
            try await stream.runMockRound()
        } catch {
            streamState = .failed(Self.message(for: error))
        }
    }

    func leaveRoom() {
        streamTask?.cancel()
        streamTask = nil
        stream?.close()
        stream = nil
        room = nil
        streamState = .idle
    }

    // MARK: - Helpers

    static var defaultBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["RT_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "RTAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }

    static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.message
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络请求失败：\(nsError.localizedDescription)"
        }
        return error.localizedDescription
    }
}
