import Foundation
import Observation

/// In-memory projection of a roundtable's event stream.
///
/// The model is deliberately free of networking and SwiftUI so it can be
/// exercised with plain unit tests; the app feeds it decoded envelopes.
@MainActor
@Observable
public final class RoundtableRoomModel {
    public private(set) var snapshot: RoundtableSnapshot?
    public private(set) var participants: [Participant] = []
    public private(set) var messages: [Message] = []
    public private(set) var status: RoundtableStatus?
    public private(set) var currentRound = 0
    public private(set) var activeParticipantId: UUID?
    public private(set) var activeTurn: ScheduledTurn?
    public private(set) var pausePending = false
    public private(set) var failures: [TurnFailure] = []
    public private(set) var budgetExhaustion: BudgetExhaustion?
    public private(set) var summary: RoundSummary?
    public private(set) var lastVisibleMessageID: UUID?

    /// Last persisted sequence the client has applied. ``room.joined`` never
    /// moves it (see docs/adr/0002).
    public private(set) var lastSequence = 0

    private var seenEventIds: Set<UUID> = []
    private var seenEventIDOrder: [UUID] = []
    private var seenMessageIds: Set<UUID> = []
    private var bufferedEvents: [Int: EventEnvelope] = [:]

    private let maxSeenEventIDs = 512

    public init() {}

    /// Seeds the projection from a REST snapshot before the socket connects.
    /// The cursor starts at the snapshot's last sequence so replay is scoped to
    /// events the client has not seen.
    public func seed(_ snapshot: RoundtableSnapshot, cursor: Int? = nil) {
        update(from: snapshot)
        lastSequence = cursor ?? snapshot.lastSequence
    }

    /// Applies an authoritative command response without discarding rendered
    /// messages. Long-lived state lives in the event stream; command responses
    /// fill the gap for idempotent calls that intentionally emit no new event.
    public func update(from snapshot: RoundtableSnapshot) {
        self.snapshot = snapshot
        participants = snapshot.participants
        status = snapshot.status
        currentRound = snapshot.currentRound
        pausePending = snapshot.pausePending ?? false
        activeTurn = snapshot.activeTurn
        activeParticipantId = snapshot.activeTurn?.roundtableAgentId
    }

    public func restore(_ state: StoredRoomState) {
        update(from: state.snapshot)
        messages = []
        seenMessageIds = []
        for message in state.messages {
            appendMessage(message)
        }
        failures = []
        for failure in state.failures {
            appendFailure(failure)
        }
        budgetExhaustion = state.budgetExhaustion
        summary = state.summary
        lastSequence = state.lastSequence
        seenEventIds = []
        seenEventIDOrder = []
        for eventID in state.seenEventIDs {
            recordSeenEventID(eventID)
        }
        lastVisibleMessageID = state.lastVisibleMessageID
        bufferedEvents = [:]
    }

    public func setLastVisibleMessage(_ messageID: UUID?) {
        guard let messageID else {
            lastVisibleMessageID = nil
            return
        }
        guard seenMessageIds.contains(messageID) else { return }
        lastVisibleMessageID = messageID
    }

    public func storedState(savedAt: Date) -> StoredRoomState {
        guard let snapshot else {
            preconditionFailure("A room must be seeded before it can be stored.")
        }
        return StoredRoomState(
            snapshot: snapshot,
            messages: messages,
            failures: failures,
            budgetExhaustion: budgetExhaustion,
            summary: summary,
            lastSequence: lastSequence,
            seenEventIDs: seenEventIDOrder,
            lastVisibleMessageID: lastVisibleMessageID,
            savedAt: savedAt
        )
    }

    public func apply(_ envelope: EventEnvelope) {
        guard !seenEventIds.contains(envelope.eventId) else { return }
        guard envelope.sequence == 0 || envelope.sequence > lastSequence else { return }

        if case let .joined(joined) = envelope.payload,
           joined.replay?.cursorExpired == true {
            resetToJoinSnapshot(joined)
            return
        }

        if envelope.sequence > 0, envelope.sequence > lastSequence + 1 {
            bufferedEvents[envelope.sequence] = envelope
            return
        }

        applyContiguousEvent(envelope)
        applyBufferedEvents()
    }

    private func applyContiguousEvent(_ envelope: EventEnvelope) {
        recordSeenEventID(envelope.eventId)

        handle(envelope.payload)

        if envelope.sequence > 0 {
            lastSequence = envelope.sequence
        }
    }

    private func applyBufferedEvents() {
        while let event = bufferedEvents.removeValue(forKey: lastSequence + 1) {
            guard !seenEventIds.contains(event.eventId), event.sequence > lastSequence else {
                continue
            }
            applyContiguousEvent(event)
        }
    }

    private func recordSeenEventID(_ eventID: UUID) {
        guard seenEventIds.insert(eventID).inserted else { return }
        seenEventIDOrder.append(eventID)
        if seenEventIDOrder.count > maxSeenEventIDs {
            let expired = seenEventIDOrder.removeFirst()
            seenEventIds.remove(expired)
        }
    }

    private func handle(_ payload: EventPayload) {
        switch payload {
        case let .joined(joined):
            applyJoin(joined)
        case .roundStarted, .roundCompleted:
            applyRoundEvent(payload)
        case .agentThinking, .agentTyping, .agentPassed:
            applyAgentEvent(payload)
        case let .messageCompleted(message):
            applyCompletedMessage(message)
        case let .agentFailed(failure):
            applyFailure(failure)
        case let .budgetExhausted(exhaustion):
            applyBudgetExhaustion(exhaustion)
        case let .summaryStarted(started):
            status = .summarizing
            snapshot?.status = .summarizing
            currentRound = started.round
            activeTurn = nil
            activeParticipantId = nil
        case let .summaryCompleted(completed):
            summary = completed.summary
            status = .completed
            snapshot?.status = .completed
            activeTurn = nil
            activeParticipantId = nil
        case .pausePending, .paused, .resumed, .ended:
            applyRoomControl(payload)
        case .unknown:
            // Forward compatibility: the payload is ignored, but the cursor
            // still advances or reconnects would replay the event forever.
            break
        }
    }

    private func applyRoundEvent(_ payload: EventPayload) {
        switch payload {
        case let .roundStarted(started):
            currentRound = started.round
        case let .roundCompleted(round):
            currentRound = round.round
            status = round.round >= (snapshot?.maxRounds ?? 2) ? .completed : .running
            activeTurn = nil
        default:
            break
        }
    }

    private func applyAgentEvent(_ payload: EventPayload) {
        guard let activity = agentActivity(from: payload) else { return }
        switch payload {
        case .agentThinking:
            apply(thinking: activity)
        case .agentTyping:
            mark(activity.agentId, as: .typing)
            activeParticipantId = activity.agentId
        default:
            mark(activity.agentId, as: .passed)
            activeParticipantId = nil
            if activity.turnId == activeTurn?.turnId {
                activeTurn = nil
            }
        }
    }

    private func agentActivity(from payload: EventPayload) -> AgentActivity? {
        switch payload {
        case let .agentThinking(activity), let .agentTyping(activity), let .agentPassed(activity):
            return activity
        default:
            return nil
        }
    }

    private func applyCompletedMessage(_ message: Message) {
        appendMessage(message)
        if let agentId = message.author.roundtableAgentId {
            mark(agentId, as: .completed)
        }
        activeParticipantId = nil
        if message.turnId == activeTurn?.turnId {
            activeTurn = nil
        }
    }

    private func applyRoomControl(_ payload: EventPayload) {
        switch payload {
        case .pausePending:
            pausePending = true
        case let .paused(changed):
            applyRoomState(changed, clearsTurn: true)
        case let .resumed(changed):
            applyRoomState(changed, clearsTurn: false)
        case let .ended(changed):
            applyRoomState(changed, clearsTurn: true)
            if let agentId = changed.cancelledAgentId {
                mark(agentId, as: .waiting)
            }
        default:
            break
        }
    }

    private func applyRoomState(_ changed: RoomStateChanged, clearsTurn: Bool) {
        status = changed.status
        pausePending = false
        if clearsTurn {
            activeTurn = nil
            activeParticipantId = nil
        }
    }

    private func applyJoin(_ joined: JoinedRoom) {
        let hadLocalSnapshot = snapshot != nil
        snapshot = joined.roundtable
        participants = joined.roundtable.participants
        status = joined.roundtable.status
        currentRound = joined.roundtable.currentRound
        pausePending = joined.roundtable.pausePending ?? false
        activeTurn = joined.roundtable.activeTurn
        activeParticipantId = joined.roundtable.activeTurn?.roundtableAgentId
        for message in joined.messages {
            appendMessage(message)
        }
        for failure in joined.failures {
            appendFailure(failure)
        }
        if let joinedSummary = joined.summary {
            summary = joinedSummary
        }
        if !hadLocalSnapshot {
            lastSequence = joined.roundtable.lastSequence
        }
    }

    private func resetToJoinSnapshot(_ joined: JoinedRoom) {
        messages = []
        failures = []
        seenMessageIds = []
        bufferedEvents = [:]
        budgetExhaustion = nil
        summary = nil
        applyJoin(joined)
        lastSequence = joined.roundtable.lastSequence
        if let selected = lastVisibleMessageID,
           !seenMessageIds.contains(selected) {
            lastVisibleMessageID = nil
        }
    }

    private func appendMessage(_ message: Message) {
        guard seenMessageIds.insert(message.id).inserted else { return }
        messages.append(message)
    }

    private func appendFailure(_ failure: TurnFailure) {
        guard !failures.contains(where: { $0.turnId == failure.turnId }) else { return }
        failures.append(failure)
    }

    private func applyFailure(_ failure: TurnFailure) {
        appendFailure(failure)
        mark(failure.agentId, as: .failed)
        if failure.turnId == activeTurn?.turnId {
            activeTurn = nil
            activeParticipantId = nil
        }
    }

    private func applyBudgetExhaustion(_ exhaustion: BudgetExhaustion) {
        guard budgetExhaustion == nil else { return }
        budgetExhaustion = exhaustion
        status = .completed
        activeTurn = nil
        activeParticipantId = nil
    }

    private func mark(_ participantId: UUID, as state: AgentState) {
        guard let index = participants.firstIndex(where: { $0.id == participantId }) else { return }
        participants[index].state = state
    }

    private func apply(thinking activity: AgentActivity) {
        mark(activity.agentId, as: .thinking)
        activeParticipantId = activity.agentId
        guard let turnId = activity.turnId,
              let round = activity.round,
              let participant = participants.first(where: { $0.id == activity.agentId })
        else { return }

        activeTurn = ScheduledTurn(
            turnId: turnId,
            round: round,
            roundtableAgentId: activity.agentId,
            position: participant.position,
            agentKey: participant.agent.key,
            agentName: participant.agent.name
        )
    }
}
