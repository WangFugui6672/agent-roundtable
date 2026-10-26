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

    /// Last persisted sequence the client has applied. ``room.joined`` never
    /// moves it (see docs/adr/0002).
    public private(set) var lastSequence = 0

    private var seenEventIds: Set<UUID> = []
    private var seenMessageIds: Set<UUID> = []

    public init() {}

    /// Seeds the projection from a REST snapshot before the socket connects.
    /// The cursor starts at the snapshot's last sequence so replay is scoped to
    /// events the client has not seen.
    public func seed(_ snapshot: RoundtableSnapshot) {
        update(from: snapshot)
        lastSequence = snapshot.lastSequence
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

    public func apply(_ envelope: EventEnvelope) {
        guard !seenEventIds.contains(envelope.eventId) else { return }
        guard envelope.sequence == 0 || envelope.sequence > lastSequence else { return }
        seenEventIds.insert(envelope.eventId)

        handle(envelope.payload)

        if envelope.sequence > 0 {
            lastSequence = envelope.sequence
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
    }

    private func appendMessage(_ message: Message) {
        guard seenMessageIds.insert(message.id).inserted else { return }
        messages.append(message)
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
