import RoundtableCore
import SwiftUI

struct UserControlBar: View {
    @Environment(AppModel.self) private var model
    let room: RoundtableRoomModel

    @State private var draft = ""
    @State private var mentionedAgentIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 10) {
            if !mentionedAgentIDs.isEmpty {
                mentionChips
            }

            HStack(alignment: .bottom, spacing: 8) {
                mentionMenu
                TextField("补充观点…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("room.user-message.input")

                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSendingUserMessage
                        || room.status == .completed
                )
                .accessibilityLabel("发送")
                .accessibilityIdentifier("room.user-message.send")
            }

            HStack(spacing: 10) {
                generationButton
                pauseResumeButton
                endButton
                Spacer()
                Button {
                    Task { await model.runMockRound() }
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isMockRunning
                        || model.isFirstRoundRunning
                        || room.status == .paused
                        || room.status == .completed
                )
                .accessibilityLabel("播放 Mock")
                .accessibilityIdentifier("room.mock")
            }

            if let error = model.controlError ?? model.turnError ?? model.streamError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("room.control.error")
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
    }

    private var mentionMenu: some View {
        Menu {
            ForEach(room.participants) { participant in
                Button {
                    toggleMention(participant.id)
                } label: {
                    if mentionedAgentIDs.contains(participant.id) {
                        Label(participant.agent.name, systemImage: "checkmark")
                    } else {
                        Text(participant.agent.name)
                    }
                }
            }
        } label: {
            Image(systemName: "at")
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("点名 Agent")
        .accessibilityIdentifier("room.user-message.mention")
    }

    private var mentionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedParticipants) { participant in
                    Button {
                        toggleMention(participant.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text("@\(participant.agent.name)")
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("取消点名 \(participant.agent.name)")
                }
            }
        }
    }

    @ViewBuilder
    private var generationButton: some View {
        if room.status != .paused, room.status != .completed, !room.pausePending {
            Button {
                model.startGeneration()
            } label: {
                if model.isFirstRoundRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isFirstRoundRunning
                    || !model.hasConfiguredProvider
                    || !model.isSceneActive
            )
            .accessibilityLabel(room.currentRound == 0 ? "开始讨论" : "继续自动讨论")
            .accessibilityIdentifier("room.round.start")
        }
    }

    @ViewBuilder
    private var pauseResumeButton: some View {
        if room.status == .paused || room.pausePending {
            Button {
                Task { await model.resumeDiscussion() }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isChangingDiscussion)
            .accessibilityLabel("继续")
            .accessibilityIdentifier("room.resume")
        } else if room.status != .completed {
            Button {
                Task { await model.pauseDiscussion() }
            } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.isChangingDiscussion)
            .accessibilityLabel(room.pausePending ? "将在当前发言后暂停" : "暂停")
            .accessibilityIdentifier("room.pause")
        }
    }

    @ViewBuilder
    private var endButton: some View {
        if room.status != .completed {
            Button(role: .destructive) {
                Task { await model.endDiscussion() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.isChangingDiscussion)
            .accessibilityLabel("结束讨论")
            .accessibilityIdentifier("room.end")
        }
    }

    private var selectedParticipants: [Participant] {
        room.participants.filter { mentionedAgentIDs.contains($0.id) }
    }

    private func toggleMention(_ id: UUID) {
        if mentionedAgentIDs.contains(id) {
            mentionedAgentIDs.remove(id)
        } else if mentionedAgentIDs.count < 3 {
            mentionedAgentIDs.insert(id)
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let mentions = Array(mentionedAgentIDs)
        Task {
            await model.sendUserMessage(body, mentionedAgentIDs: mentions)
            guard model.controlError == nil else { return }
            draft = ""
            mentionedAgentIDs.removeAll()
        }
    }
}

private extension AppModel {
    var turnError: String? {
        guard case let .failed(_, message, _) = turnState else { return nil }
        return message
    }

    var streamError: String? {
        guard case let .failed(message) = streamState else { return nil }
        return message
    }
}
