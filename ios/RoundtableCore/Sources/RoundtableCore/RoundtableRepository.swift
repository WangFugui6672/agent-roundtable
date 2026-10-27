import Foundation
import Observation

@MainActor
public protocol RoundtableRoomStore {
    func save(_ state: StoredRoomState) throws
    func load(roomID: UUID) throws -> StoredRoomState?
    func loadMostRecent() throws -> StoredRoomState?
    func loadAll() throws -> [StoredRoomState]
    func markDeleted(roomID: UUID) throws
    func delete(roomID: UUID) throws
}

public extension RoundtableRoomStore {
    func loadAll() throws -> [StoredRoomState] {
        try loadMostRecent().map { [$0] } ?? []
    }

    func markDeleted(roomID: UUID) throws {}
}

@MainActor
public final class InMemoryRoomStore: RoundtableRoomStore {
    private var rooms: [UUID: StoredRoomState] = [:]
    private var deletedRoomIDs: Set<UUID> = []

    public init() {}

    public func save(_ state: StoredRoomState) throws {
        guard !deletedRoomIDs.contains(state.snapshot.id) else { return }
        rooms[state.snapshot.id] = state
    }

    public func load(roomID: UUID) throws -> StoredRoomState? {
        rooms[roomID]
    }

    public func loadMostRecent() throws -> StoredRoomState? {
        rooms.values.max { $0.savedAt < $1.savedAt }
    }

    public func loadAll() throws -> [StoredRoomState] {
        rooms.values.filter { !deletedRoomIDs.contains($0.snapshot.id) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func markDeleted(roomID: UUID) throws {
        deletedRoomIDs.insert(roomID)
    }

    public func delete(roomID: UUID) throws {
        try markDeleted(roomID: roomID)
        rooms[roomID] = nil
    }
}

@MainActor
@Observable
public final class RoundtableRepository {
    public private(set) var room: RoundtableRoomModel?
    public private(set) var connectionState: RoundtableConnectionState = .idle
    public var connectionStateHandler: ((RoundtableConnectionState) -> Void)?

    private var api: APIClient
    let store: any RoundtableRoomStore
    private let socketFactory: any RoundtableSocketFactory
    private let reconnectPolicy: ReconnectPolicy
    private let reconnectSleep: RoundtableStream.Sleep
    private var stream: RoundtableStream?
    private var streamTask: Task<Void, Never>?
    private var connectedGuestSessionID: UUID?
    private var connectedRoomID: UUID?

    public init(
        api: APIClient,
        store: any RoundtableRoomStore,
        socketFactory: any RoundtableSocketFactory = URLSessionSocketFactory(),
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        reconnectSleep: @escaping RoundtableStream.Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.api = api
        self.store = store
        self.socketFactory = socketFactory
        self.reconnectPolicy = reconnectPolicy
        self.reconnectSleep = reconnectSleep
    }

    public var baseURL: URL {
        api.baseURL
    }

    public func setGuestSession(_ id: UUID?) {
        api = api.withGuestSession(id)
    }

    // MARK: - Remote operations

    public func createGuestSession() async throws -> GuestSession {
        try await api.createGuestSession()
    }

    public func fetchAgentProfiles() async throws -> [AgentProfile] {
        try await api.fetchAgentProfiles()
    }

    public func fetchHistory() async throws -> [RoundtableSnapshot] {
        try await api.fetchRoundtables()
    }

    public func rotateGuestSession() async throws -> GuestSession {
        let session = try await api.rotateGuestSession()
        api = api.withGuestSession(session.id)
        return session
    }

    public func deleteGuestSession() async throws {
        try await api.deleteGuestSession()
        api = api.withGuestSession(nil)
    }

    public func createRoundtable(
        topic: String,
        agentProfileIDs: [UUID],
        provider: ProviderMetadata?
    ) async throws -> RoundtableSnapshot {
        try await api.createRoundtable(
            topic: topic,
            agentProfileIds: agentProfileIDs,
            provider: provider
        )
    }

    public func createFollowUp(
        parentRoundtableID: UUID,
        topic: String
    ) async throws -> RoundtableSnapshot {
        try await api.createFollowUp(
            parentRoundtableID: parentRoundtableID,
            topic: topic
        )
    }

    public func nextTurn(roundtableID: UUID) async throws -> NextTurnResponse {
        try await api.nextTurn(roundtableID: roundtableID)
    }

    public func submitMessage(
        roundtableID: UUID,
        submission: MessageSubmission
    ) async throws -> EventEnvelope {
        try await api.submitMessage(
            roundtableID: roundtableID,
            submission: submission
        )
    }

    public func passTurn(
        roundtableID: UUID,
        agentID: UUID,
        turnID: UUID,
        usage: ProviderUsageReport?
    ) async throws -> EventEnvelope {
        try await api.passTurn(
            roundtableID: roundtableID,
            agentID: agentID,
            turnID: turnID,
            usage: usage
        )
    }

    public func reportTurnFailure(
        roundtableID: UUID,
        submission: TurnFailureSubmission
    ) async throws -> EventEnvelope {
        try await api.reportTurnFailure(
            roundtableID: roundtableID,
            submission: submission
        )
    }

    public func regenerateMessage(
        roundtableID: UUID,
        messageID: UUID
    ) async throws -> RegenerationResponse {
        try await api.regenerateMessage(
            roundtableID: roundtableID,
            messageID: messageID
        )
    }

    public func setKeyPoint(
        roundtableID: UUID,
        messageID: UUID,
        isKeyPoint: Bool
    ) async throws {
        let updated = try await api.setKeyPoint(
            roundtableID: roundtableID,
            messageID: messageID,
            isKeyPoint: isKeyPoint
        )
        guard room?.snapshot?.id == roundtableID else { return }
        room?.setKeyPoint(updated.id, isKeyPoint: updated.isKeyPoint)
        try persist()
    }

    public func submitSummary(
        roundtableID: UUID,
        submission: RoundSummarySubmission
    ) async throws -> RoundSummaryResponse {
        try await api.submitSummary(
            roundtableID: roundtableID,
            submission: submission
        )
    }

    public func sendUserMessage(
        roundtableID: UUID,
        body: String,
        mentionedAgentIDs: [UUID]
    ) async throws -> RoomCommandResponse {
        try await api.sendUserMessage(
            roundtableID: roundtableID,
            body: body,
            mentionedAgentIDs: mentionedAgentIDs
        )
    }

    public func pauseRoundtable(roundtableID: UUID) async throws -> RoomCommandResponse {
        try await api.pauseRoundtable(roundtableID: roundtableID)
    }

    public func resumeRoundtable(roundtableID: UUID) async throws -> RoomCommandResponse {
        try await api.resumeRoundtable(roundtableID: roundtableID)
    }

    public func endRoundtable(roundtableID: UUID) async throws -> RoomCommandResponse {
        try await api.endRoundtable(roundtableID: roundtableID)
    }

    @discardableResult
    public func reportMessage(
        roundtableID: UUID,
        messageID: UUID,
        reason: MessageReportReason,
        details: String = ""
    ) async throws -> MessageReportReceipt {
        let receipt = try await api.reportMessage(
            roundtableID: roundtableID,
            messageID: messageID,
            reason: reason,
            details: details
        )
        if room?.snapshot?.id == roundtableID {
            room?.markMessageReported(messageID)
            try persist()
        }
        return receipt
    }

    public func fetchRoundtable(id: UUID) async throws -> RoundtableSnapshot {
        try await api.fetchRoundtable(id: id)
    }

    // MARK: - Projection and persistence

    public func restoreRecent() throws -> Bool {
        guard let state = try store.loadMostRecent() else { return false }
        let room = RoundtableRoomModel()
        room.restore(state)
        self.room = room
        return true
    }

    public func restore(roomID: UUID) throws -> Bool {
        guard let state = try store.load(roomID: roomID) else { return false }
        let room = RoundtableRoomModel()
        room.restore(state)
        self.room = room
        return true
    }

    public func loadCachedRooms() throws -> [StoredRoomState] {
        try store.loadAll()
    }

    public func present(_ snapshot: RoundtableSnapshot, cursor: Int? = nil) throws {
        let room = RoundtableRoomModel()
        room.seed(snapshot, cursor: cursor)
        self.room = room
        try persist()
    }

    public func apply(_ event: EventEnvelope) throws {
        guard let room else { return }
        room.apply(event)
        try persist()
    }

    public func apply(_ events: [EventEnvelope]) throws {
        guard let room else { return }
        for event in events {
            room.apply(event)
        }
        try persist()
    }

    public func apply(_ response: RoomCommandResponse) throws {
        guard let room else { return }
        for event in response.events {
            room.apply(event)
        }
        room.update(from: response.roundtable)
        try persist()
    }

    public func apply(_ response: RoundSummaryResponse) throws {
        guard let room, room.snapshot?.id == response.roundtable.id else { return }
        for event in response.events {
            room.apply(event)
        }
        room.update(from: response.roundtable)
        try persist()
    }

    public func update(from snapshot: RoundtableSnapshot) throws {
        guard let room else { return }
        room.update(from: snapshot)
        try persist()
    }

    public func delete(roomID: UUID) throws {
        try store.delete(roomID: roomID)
        if room?.snapshot?.id == roomID {
            room = nil
        }
    }

    public func deleteRoundtable(roomID: UUID) async throws {
        do {
            try await api.deleteRoundtable(id: roomID)
        } catch let error as APIError where error.statusCode == 404 {
            // The server already has no data; local cleanup must still finish.
        } catch {
            throw RoundtableDeletionError.server(error)
        }
        do {
            try store.markDeleted(roomID: roomID)
            try store.delete(roomID: roomID)
        } catch {
            throw RoundtableDeletionError.local(error)
        }
        if room?.snapshot?.id == roomID {
            disconnect(reason: nil)
            room = nil
        }
    }

    public func deleteLocalRoom(roomID: UUID) throws {
        try store.markDeleted(roomID: roomID)
        try store.delete(roomID: roomID)
        if room?.snapshot?.id == roomID {
            disconnect(reason: nil)
            room = nil
        }
    }

    // MARK: - Live connection

    public func connect(guestSessionID: UUID) {
        guard let room, let roomID = room.snapshot?.id else { return }
        if stream != nil,
           connectedGuestSessionID == guestSessionID,
           connectedRoomID == roomID {
            return
        }
        disconnect(reason: nil)
        connectedGuestSessionID = guestSessionID
        connectedRoomID = roomID
        let stream = RoundtableStream(
            baseURL: api.baseURL,
            roomID: roomID,
            guestSessionID: guestSessionID,
            cursor: room.lastSequence,
            socketFactory: socketFactory,
            reconnectPolicy: reconnectPolicy,
            sleep: reconnectSleep
        )
        self.stream = stream
        updateConnectionState(.connecting)

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await item in stream.events() {
                    switch item {
                    case let .connection(state):
                        self.updateConnectionState(state)
                    case let .envelope(event):
                        do {
                            try self.apply(event)
                            let resetCursor: Bool
                            if case let .joined(joined) = event.payload {
                                resetCursor = joined.replay?.cursorExpired == true
                            } else {
                                resetCursor = false
                            }
                            stream.confirmProcessed(
                                cursor: self.room?.lastSequence ?? 0,
                                resetCursor: resetCursor
                            )
                        } catch {
                            stream.close()
                            self.updateConnectionState(
                                .disconnected("圆桌状态无法保存：\(error.localizedDescription)")
                            )
                            return
                        }
                    }
                }
            } catch {
                self.updateConnectionState(.disconnected(error.localizedDescription))
            }
            if !Task.isCancelled, self.stream === stream {
                self.updateConnectionState(.disconnected("连接已断开。"))
            }
        }
    }

    public func disconnect(reason: String? = "连接已暂停。") {
        streamTask?.cancel()
        streamTask = nil
        stream?.close()
        stream = nil
        connectedGuestSessionID = nil
        connectedRoomID = nil
        updateConnectionState(reason.map(RoundtableConnectionState.disconnected) ?? .idle)
    }

    public func runMockRound() async throws {
        guard let stream else { throw StreamError.notConnected }
        try await stream.runMockRound()
    }

    public func leaveRoom() {
        disconnect(reason: nil)
        room = nil
    }

    func persist() throws {
        guard let room else { return }
        try store.save(room.storedState(savedAt: Date()))
    }

    private func updateConnectionState(_ state: RoundtableConnectionState) {
        connectionState = state
        connectionStateHandler?(state)
    }
}
