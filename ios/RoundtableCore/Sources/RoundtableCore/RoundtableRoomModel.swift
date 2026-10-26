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
        self.snapshot = snapshot
        participants = snapshot.participants
        status = snapshot.status
        currentRound = snapshot.currentRound
        lastSequence = snapshot.lastSequence
    }

    public func apply(_ envelope: EventEnvelope) {
        guard !seenEventIds.contains(envelope.eventId) else { return }
        guard envelope.sequence == 0 || envelope.sequence > lastSequence else { return }
        seenEventIds.insert(envelope.eventId)

        switch envelope.payload {
        case let .joined(joined):
            applyJoin(joined)
        case let .roundStarted(started):
            currentRound = started.round
        case let .agentThinking(activity):
            mark(activity.agentId, as: .thinking)
            activeParticipantId = activity.agentId
        case let .agentTyping(activity):
            mark(activity.agentId, as: .typing)
            activeParticipantId = activity.agentId
        case let .agentPassed(activity):
            mark(activity.agentId, as: .passed)
            activeParticipantId = nil
        case let .messageCompleted(message):
            appendMessage(message)
            mark(message.author.roundtableAgentId, as: .completed)
            activeParticipantId = nil
        case let .roundCompleted(round):
            currentRound = round.round
            status = round.round >= (snapshot?.maxRounds ?? 2) ? .completed : .running
        case .unknown:
            // Forward compatibility: the payload is ignored, but the cursor
            // still advances or reconnects would replay the event forever.
            break
        }

        if envelope.sequence > 0 {
            lastSequence = envelope.sequence
        }
    }

    private func applyJoin(_ joined: JoinedRoom) {
        snapshot = joined.roundtable
        participants = joined.roundtable.participants
        status = joined.roundtable.status
        currentRound = joined.roundtable.currentRound
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
}
