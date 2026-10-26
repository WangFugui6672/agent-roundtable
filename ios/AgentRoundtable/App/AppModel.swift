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
    var isFirstRoundRunning = false
    private(set) var createError: String?
    var controlError: String?
    var failureCode: String?
    var failureRetryable = false
    var scheduledTurn: ScheduledTurn?
    var isSendingUserMessage = false
    var isChangingDiscussion = false

    /// One real-provider turn at a time (Issue #4). Scheduling three agents in
    /// order is Issue #5's job.
    enum TurnState: Equatable {
        case idle
        case thinking(agentID: UUID)
        case typing(agentID: UUID, text: String)
        case submitting(agentID: UUID)
        case completed(agentID: UUID)
        case passed(agentID: UUID)
        case roundCompleted(round: Int)
        case paused
        case ended
        /// `partial` keeps the streamed text so a failed turn is retryable
        /// without losing what the model already produced (PRD 7.12).
        case failed(agentID: UUID, message: String, partial: String?)

        var isBusy: Bool {
            switch self {
            case .thinking, .typing, .submitting: return true
            case .idle, .completed, .passed, .roundCompleted, .paused, .ended, .failed:
                return false
            }
        }
    }

    var turnState: TurnState = .idle

    // Provider state (Issue #3). Secrets never enter these properties: only the
    // non-secret configuration is exposed to the UI. They are internal so the
    // `AppModel+Provider` / `AppModel+RealTurn` extensions can own the writes.
    var activeProvider: ProviderKind?
    var providerError: String?
    var providerCheckMessage: String?
    var isSavingProvider = false
    var isCheckingProvider = false

    var api: APIClient
    private var guestSessionID: UUID?
    private var stream: RoundtableStream?
    private var streamTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var generationID: UUID?
    var reportedFailureTurnIDs: Set<UUID> = []
    var isEnding = false
    let defaults: UserDefaults
    let providerStore: ProviderStore
    let probe: ProviderProbe
    let chatClient: ProviderChatClient

    private static let sessionKey = "roundtable.guestSessionID"
    static let activeProviderKey = "roundtable.activeProviderKind"

    init(
        defaults: UserDefaults = .standard,
        providerStore: ProviderStore? = nil,
        probe: ProviderProbe = ProviderProbe(),
        chatClient: ProviderChatClient = ProviderChatClient(),
        api: APIClient? = nil
    ) {
        self.defaults = defaults
        self.api = api ?? APIClient(baseURL: Self.defaultBaseURL)
        self.providerStore = providerStore ?? ProviderStore()
        self.probe = probe
        self.chatClient = chatClient

        #if DEBUG
        if ProcessInfo.processInfo.environment["RT_RESET_PROVIDER_STATE"] == "1" {
            self.providerStore.reset()
            defaults.removeObject(forKey: Self.activeProviderKey)
        }
        if ProcessInfo.processInfo.environment["RT_RESET_GUEST_SESSION"] == "1" {
            defaults.removeObject(forKey: Self.sessionKey)
        }
        #endif

        if let raw = defaults.string(forKey: Self.activeProviderKey) {
            self.activeProvider = ProviderKind(rawValue: raw)
        }
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
                phase = .failed(Self.userMessage(for: error))
            }
        } catch {
            phase = .failed(Self.userMessage(for: error))
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
        // A selected-but-unusable provider must be fixed instead of silently
        // starting a Mock roundtable (PRD 7.13).
        return providerIncompleteMessage == nil
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

        if let incomplete = providerIncompleteMessage {
            createError = "Provider 配置不完整：\(incomplete)"
            return
        }

        isCreating = true
        createError = nil
        defer { isCreating = false }

        do {
            let snapshot = try await api.createRoundtable(
                topic: trimmed,
                agentProfileIds: selectedProfileIDs,
                provider: providerMetadata
            )
            open(snapshot)
        } catch {
            createError = Self.userMessage(for: error)
        }
    }

    // MARK: - Room

    /// Projects a snapshot into the room without opening the socket; `open`
    /// adds the stream. Splitting the two keeps the projection testable
    /// without a boolean flag.
    func present(_ snapshot: RoundtableSnapshot) {
        let room = RoundtableRoomModel()
        room.seed(snapshot)
        self.room = room
    }

    func open(_ snapshot: RoundtableSnapshot) {
        present(snapshot)
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
                self?.streamState = .failed(Self.userMessage(for: error))
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
            streamState = .failed(Self.userMessage(for: error))
        }
    }

    func leaveRoom() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isEnding = false
        streamTask?.cancel()
        streamTask = nil
        stream?.close()
        stream = nil
        room = nil
        streamState = .idle
        turnState = .idle
        scheduledTurn = nil
        failureCode = nil
        failureRetryable = false
        reportedFailureTurnIDs.removeAll()
        isFirstRoundRunning = false
        controlError = nil
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

    /// Single mapping from any error to copy shown in the UI. Provider errors
    /// already carry actionable text (PRD 7.13), so they win over the fallback.
    static func userMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.message
        }
        if let validation = error as? ProviderValidationError {
            return validation.message
        }
        if let keychain = error as? KeychainError {
            return keychain.message
        }
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
