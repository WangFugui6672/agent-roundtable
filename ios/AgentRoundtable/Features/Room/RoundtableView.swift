import RoundtableCore
import SwiftUI

struct RoundtableView: View {
    @Environment(AppModel.self) private var model
    let room: RoundtableRoomModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            participantsStrip
            Divider()
            turnStatus
            messageList
            Divider()
            footer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("圆桌")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("离开") { model.leaveRoom() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(room.snapshot?.topic ?? "")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                StatusPill(text: statusBadge.text, tint: statusBadge.tint)
                StatusPill(text: streamBadge.text, tint: streamBadge.tint)
                Spacer()
                Text("第 \(room.currentRound)/\(room.snapshot?.maxRounds ?? 2) 轮")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var participantsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(room.participants) { participant in
                    Button {
                        Task { await model.runRealTurn(participant: participant) }
                    } label: {
                        ParticipantChip(
                            participant: participant,
                            isActive: room.activeParticipantId == participant.id
                                || isTurnAgent(participant.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.turnState.isBusy)
                    .accessibilityIdentifier("room.speak.\(participant.position)")
                    .accessibilityHint("让 \(participant.agent.name) 使用真实模型发言")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var turnStatus: some View {
        switch model.turnState {
        case .idle:
            EmptyView()
        case let .thinking(agentID):
            turnBanner(
                text: "\(name(of: agentID)) 正在思考…",
                icon: "brain",
                tint: .orange,
                identifier: "room.turn.thinking"
            )
        case let .submitting(agentID):
            turnBanner(
                text: "正在提交 \(name(of: agentID)) 的发言…",
                icon: "arrow.up.circle",
                tint: .secondary,
                identifier: "room.turn.submitting"
            )
        case let .failed(_, message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("room.turnError")
                Spacer(minLength: 8)
                Button("重试") { model.resetTurn() }
                    .font(.footnote)
                    .accessibilityIdentifier("room.turn.retry")
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
        case .typing:
            turnBanner(
                text: "\(name(of: draftAgentID)) 正在输入…",
                icon: "ellipsis.bubble",
                tint: .accentColor,
                identifier: "room.turn.typing"
            )
        }
    }

    private func turnBanner(
        text: String,
        icon: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var draftAgentID: UUID? {
        if case let .typing(agentID, _) = model.turnState { return agentID }
        return nil
    }

    private var draftText: String? {
        if case let .typing(_, text) = model.turnState { return text }
        return nil
    }

    private func isTurnAgent(_ id: UUID) -> Bool {
        switch model.turnState {
        case let .thinking(agentID), let .typing(agentID, _), let .submitting(agentID),
             let .failed(agentID, _):
            return agentID == id
        case .idle:
            return false
        }
    }

    private func name(of id: UUID?) -> String {
        guard let id, let participant = room.participants.first(where: { $0.id == id }) else {
            return "Agent"
        }
        return participant.agent.name
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if room.messages.isEmpty && draftText == nil {
                        emptyState
                    } else {
                        ForEach(room.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                        if let draftText {
                            StreamingMessageRow(
                                name: name(of: draftAgentID),
                                text: draftText
                            )
                            .id("room.turn.draft")
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: room.messages.count) { _, _ in
                guard let last = room.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: draftText ?? "") { _, _ in
                guard draftText != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("room.turn.draft", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("圆桌已经建好，还没有发言")
                .font(.headline)
                .accessibilityIdentifier("room.empty")
            Text("点上方任意参与者，可以让 TA 用已配置的 Provider 真实发言；也可以先播放 Mock 事件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.runMockRound() }
            } label: {
                HStack(spacing: 6) {
                    if model.isMockRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("播放 Mock 一轮", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isMockRunning)
            .accessibilityIdentifier("room.mock")

            Spacer()

            if case let .failed(message) = model.streamState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
    }

    private var statusBadge: (text: String, tint: Color) {
        guard let status = room.status else { return ("准备中", .secondary) }
        switch status {
        case .draft: return ("草稿", .secondary)
        case .ready: return ("就绪", .secondary)
        case .running: return ("讨论中", .green)
        case .paused: return ("已暂停", .orange)
        case .summarizing: return ("总结中", .orange)
        case .completed: return ("已结束", .blue)
        case .failed: return ("失败", .red)
        case .archived: return ("已归档", .secondary)
        case .unknown: return ("未知状态", .secondary)
        }
    }

    private var streamBadge: (text: String, tint: Color) {
        switch model.streamState {
        case .idle: return ("未连接", .secondary)
        case .connecting: return ("连接中", .orange)
        case .connected: return ("已连接", .green)
        case .closed: return ("已断开", .secondary)
        case .failed: return ("连接失败", .red)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

private struct ParticipantChip: View {
    let participant: Participant
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            Text(participant.agent.name)
                .font(.subheadline.weight(.medium))
            Text(stateText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        .overlay(
            Capsule().strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(participant.agent.name)，\(stateText)")
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch participant.state {
        case .thinking, .typing:
            ProgressView()
                .controlSize(.mini)
        default:
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
        }
    }

    private var stateColor: Color {
        switch participant.state {
        case .completed: .green
        case .passed: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var stateText: String {
        switch participant.state {
        case .waiting: "等待"
        case .thinking: "思考中"
        case .typing: "输入中"
        case .passed: "沉默"
        case .completed: "已发言"
        case .failed: "失败"
        case .unknown: "—"
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(message.author.name)
                    .font(.subheadline.weight(.semibold))
                StanceBadge(messageType: message.messageType, stance: message.stance)
                Spacer()
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(message.claim)
                .font(.body.weight(.medium))

            Text(message.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !message.references.isEmpty {
                Label("引用了 \(message.references.count) 条观点", systemImage: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.author.name)：\(message.claim)。\(message.body)")
    }
}

private struct StanceBadge: View {
    let messageType: MessageType
    let stance: Stance?

    var body: some View {
        Text(badge.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(badge.tint.opacity(0.15)))
            .foregroundStyle(badge.tint)
    }

    private var badge: (label: String, tint: Color) {
        if let stance {
            switch stance {
            case .challenge: return ("质疑", .red)
            case .support: return ("支持", .green)
            case .supplement: return ("补充", .blue)
            case .question: return ("追问", .orange)
            case .unknown: return ("其他", .secondary)
            }
        }
        switch messageType {
        case .proposal: return ("提议", .secondary)
        case .summary: return ("总结", .secondary)
        case .pass: return ("沉默", .secondary)
        case .question: return ("提问", .secondary)
        default: return ("发言", .secondary)
        }
    }
}

private struct StreamingMessageRow: View {
    let name: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.turn.draft")
    }
}
