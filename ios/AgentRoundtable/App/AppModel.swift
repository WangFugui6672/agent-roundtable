import Foundation
import Observation
import RoundtableCore
import SwiftData

enum AppTurnState: Equatable {
    case idle
    case thinking(agentID: UUID)
    case typing(agentID: UUID, text: String)
    case submitting(agentID: UUID)
    case completed(agentID: UUID)
    case passed(agentID: UUID)
    case roundCompleted(round: Int)
    case paused
    case ended
    /// `partial` keeps streamed text so a failed turn remains retryable.
    case failed(agentID: UUID, message: String, partial: String?)

    var isBusy: Bool {
        switch self {
        case .thinking, .typing, .submitting: return true
        case .idle, .completed, .passed, .roundCompleted, .paused, .ended, .failed:
            return false
        }
    }
}

/// App-level orchestration: session bootstrap, roundtable creation, and the
/// WebSocket lifecycle. All UI state lives here or in ``RoundtableRoomModel``.
@MainActor
@Observable
final class AppModel {
    typealias TurnState = AppTurnState

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum StreamState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case closed
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var profiles: [AgentProfile] = []
    private(set) var selectedProfileIDs: [UUID] = []
    var room: RoundtableRoomModel? { repository.room }
    var historyEntries: [RoundtableHistoryEntry] = []
    var historyError: String?
    var isDeletingHistory = false
    var isManagingSession = false
    var isRoomPresented = false
    var isCreatingRoundtable = false
    private(set) var streamState: StreamState = .idle
    private(set) var isCreating = false
    private(set) var isMockRunning = false
    var isSceneActive = true
    var isFirstRoundRunning = false
    private(set) var createError: String?
    var controlError: String?
    var failureCode: String?
    var failureRetryable = false
    var scheduledTurn: ScheduledTurn?
    var isSendingUserMessage = false
    var isChangingDiscussion = false
    var isProviderDataNoticePresented = false
    var pendingProviderDataAction: ProviderDataAction?
    var contentSafetyNotice: String?
    var contentSafetyError: String?
    var isDeletingRoom = false
    var isRegeneratingMessage = false

    var turnState: TurnState = .idle
    var summaryState: SummaryGenerationState = .idle
    var summaryError: String?
    var summaryNeedsLocalFlag = false
    var isCreatingFollowUp = false

    // Provider state (Issue #3). Secrets never enter these properties: only the
    // non-secret configuration is exposed to the UI. They are internal so the
    // `AppModel+Provider` / `AppModel+RealTurn` extensions can own the writes.
    var activeProvider: ProviderKind?
    var providerError: String?
    var providerCheckMessage: String?
    var isSavingProvider = false
    var isCheckingProvider = false

    var guestSessionID: UUID?
    let repository: RoundtableRepository
    var generationTask: Task<Void, Never>?
    var generationID: UUID?
    var summaryTask: Task<Void, Never>?
    var summaryGenerationID: UUID?
    var reportedFailureTurnIDs: Set<UUID> = []
    var isEnding = false
    let defaults: UserDefaults
    let providerStore: ProviderStore
    let probe: ProviderProbe
    let chatClient: ProviderChatClient
    let contentPolicy: ContentPolicy
    let guestSessionStore: AnonymousSessionStore

    private static let sessionKey = "roundtable.guestSessionID"
    static let activeProviderKey = "roundtable.activeProviderKind"
    static let providerDataNoticeKey = "roundtable.providerDataNoticeAcknowledged"

    init(
        defaults: UserDefaults = .standard,
        providerStore: ProviderStore? = nil,
        probe: ProviderProbe = ProviderProbe(),
        chatClient: ProviderChatClient = ProviderChatClient(),
        contentPolicy: ContentPolicy = .standard,
        guestSessionStore: AnonymousSessionStore = AnonymousSessionStore(),
        api: APIClient? = nil,
        roomStore: (any RoundtableRoomStore)? = nil,
        socketFactory: any RoundtableSocketFactory = URLSessionSocketFactory()
    ) {
        self.defaults = defaults
        self.providerStore = providerStore ?? ProviderStore()
        self.probe = probe
        self.chatClient = chatClient
        self.contentPolicy = contentPolicy
        self.guestSessionStore = guestSessionStore
        repository = RoundtableRepository(
            api: api ?? APIClient(baseURL: Self.defaultBaseURL),
            store: roomStore ?? InMemoryRoomStore(),
            socketFactory: socketFactory
        )
        repository.connectionStateHandler = { [weak self] state in
            self?.streamState = Self.mapConnectionState(state)
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["RT_RESET_PROVIDER_STATE"] == "1" {
            self.providerStore.reset()
            defaults.removeObject(forKey: Self.activeProviderKey)
            defaults.removeObject(forKey: Self.providerDataNoticeKey)
        }
        if ProcessInfo.processInfo.environment["RT_RESET_GUEST_SESSION"] == "1" {
            try? guestSessionStore.clear()
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
        let restored = (try? repository.restoreRecent()) ?? false
        isRoomPresented = false
        reloadCachedHistory()
        if restored {
            phase = .ready
        }
        do {
            try await loadInitialState()
        } catch let error as APIError where error.code == "guest_session_required" {
            // The stored session can disappear after a database reset or the
            // retention window: drop it and register a fresh one.
            resetGuestSession()
            do {
                try await loadInitialState()
            } catch {
                handleBootstrapFailure(error, hasCachedRoom: restored)
            }
        } catch {
            handleBootstrapFailure(error, hasCachedRoom: restored)
        }
    }

    private func loadInitialState() async throws {
        let sessionID = try await ensureGuestSession()
        guestSessionID = sessionID
        repository.setGuestSession(sessionID)

        let profiles = try await repository.fetchAgentProfiles()
        self.profiles = profiles
        if selectedProfileIDs.isEmpty {
            selectedProfileIDs = profiles.map(\.id)
        }
        phase = .ready
        await refreshHistory()
        if room != nil {
            repository.connect(guestSessionID: sessionID)
        }
    }

    private func resetGuestSession() {
        try? guestSessionStore.clear()
        defaults.removeObject(forKey: Self.sessionKey)
        guestSessionID = nil
        repository.setGuestSession(nil)
    }

    private func ensureGuestSession() async throws -> UUID {
        if let stored = try guestSessionStore.load() {
            return stored
        }
        if let raw = defaults.string(forKey: Self.sessionKey),
           let legacy = UUID(uuidString: raw) {
            try guestSessionStore.save(legacy)
            defaults.removeObject(forKey: Self.sessionKey)
            return legacy
        }
        let session = try await repository.createGuestSession()
        try guestSessionStore.save(session.id)
        return session.id
    }

    private func handleBootstrapFailure(_ error: Error, hasCachedRoom: Bool) {
        if hasCachedRoom {
            phase = .ready
            streamState = .failed("当前离线，正在显示本机缓存的圆桌。")
        } else {
            phase = .failed(Self.userMessage(for: error))
        }
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
        guard validateLocalContent(trimmed) else {
            createError = contentSafetyError
            return
        }

        isCreating = true
        createError = nil
        defer { isCreating = false }

        do {
            let snapshot = try await repository.createRoundtable(
                topic: trimmed,
                agentProfileIDs: selectedProfileIDs,
                provider: providerMetadata
            )
            open(snapshot)
            contentSafetyNotice = contentPolicy.evaluate(trimmed).decision == .flag
                ? contentSafetyNotice
                : nil
        } catch {
            createError = Self.userMessage(for: error)
        }
    }

    // MARK: - Room

    /// Projects a snapshot into the room without opening the socket; `open`
    /// adds the stream. Splitting the two keeps the projection testable
    /// without a boolean flag.
    func present(_ snapshot: RoundtableSnapshot) {
        try? repository.present(snapshot)
    }

    func open(_ snapshot: RoundtableSnapshot) {
        guard (try? repository.present(snapshot)) != nil,
              let guestSessionID else {
            return
        }
        isRoomPresented = true
        isCreatingRoundtable = false
        repository.connect(guestSessionID: guestSessionID)
    }

    func runMockRound() async {
        guard !isMockRunning else { return }
        isMockRunning = true
        defer { isMockRunning = false }
        let initialStatus = room?.status
        do {
            try await repository.runMockRound()
            for _ in 0 ..< 100 {
                guard room?.status == initialStatus else {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if room?.status == .summarizing {
                await generateSummary()
            }
        } catch {
            streamState = .failed(Self.userMessage(for: error))
        }
    }

    func leaveRoom() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        summaryTask?.cancel()
        summaryTask = nil
        summaryGenerationID = nil
        isEnding = false
        repository.leaveRoom()
        streamState = .idle
        turnState = .idle
        summaryState = .idle
        summaryError = nil
        summaryNeedsLocalFlag = false
        scheduledTurn = nil
        failureCode = nil
        failureRetryable = false
        reportedFailureTurnIDs.removeAll()
        isFirstRoundRunning = false
        isCreatingFollowUp = false
        controlError = nil
        contentSafetyNotice = nil
        contentSafetyError = nil
        isRoomPresented = false
        isCreatingRoundtable = false
        reloadCachedHistory()
    }

    func markVisibleMessage(_ messageID: UUID) {
        guard room?.lastVisibleMessageID != messageID else { return }
        try? repository.markVisibleMessage(messageID)
    }

    func resetAfterRoomDeletion() {
        streamState = .idle
        turnState = .idle
        summaryState = .idle
        summaryError = nil
        summaryNeedsLocalFlag = false
        scheduledTurn = nil
        failureCode = nil
        failureRetryable = false
        reportedFailureTurnIDs.removeAll()
        isFirstRoundRunning = false
        isEnding = false
        contentSafetyNotice = nil
        contentSafetyError = nil
    }

}
