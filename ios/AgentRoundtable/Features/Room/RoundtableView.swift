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
                    ParticipantChip(
                        participant: participant,
                        isActive: room.activeParticipantId == participant.id
                            || turn.agentID == participant.id
                    )
                    .accessibilityIdentifier("room.participant.\(participant.position)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private struct TurnFailure {
        let message: String
        let partial: String?
    }

    private struct TurnBanner {
        let text: String
        let icon: String
        let tint: Color
        let identifier: String
    }

    private struct TurnPresentation {
        var banner: TurnBanner?
        var failure: TurnFailure?
        var draft: (agentName: String, text: String)?
        var agentID: UUID?
    }

    /// One switch over `turnState`; everything else in the view reads this.
    private var turn: TurnPresentation {
        func name(_ id: UUID) -> String {
            room.participants.first(where: { $0.id == id })?.agent.name ?? "Agent"
        }

        switch model.turnState {
        case .idle:
            return TurnPresentation()
        case let .thinking(agentID):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "\(name(agentID)) 正在思考…",
                    icon: "brain",
                    tint: .orange,
                    identifier: "room.turn.thinking"
                ),
                agentID: agentID
            )
        case let .typing(agentID, text):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "\(name(agentID)) 正在输入…",
                    icon: "ellipsis.bubble",
                    tint: .accentColor,
                    identifier: "room.turn.typing"
                ),
                draft: (name(agentID), text),
                agentID: agentID
            )
        case let .submitting(agentID):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "正在提交 \(name(agentID)) 的发言…",
                    icon: "arrow.up.circle",
                    tint: .secondary,
                    identifier: "room.turn.submitting"
                ),
                agentID: agentID
            )
        case let .completed(agentID):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "\(name(agentID)) 的发言已提交",
                    icon: "checkmark.circle",
                    tint: .green,
                    identifier: "room.turn.completed"
                ),
                agentID: agentID
            )
        case let .passed(agentID):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "\(name(agentID)) 已查看观点，但不发言",
                    icon: "eye.slash",
                    tint: .orange,
                    identifier: "room.turn.passed"
                ),
                agentID: agentID
            )
        case let .roundCompleted(round):
            return TurnPresentation(
                banner: TurnBanner(
                    text: "第 \(round) 轮讨论已完成",
                    icon: "checkmark.circle",
                    tint: .green,
                    identifier: "room.round.completed"
                )
            )
        case let .failed(agentID, message, partial):
            return TurnPresentation(
                failure: TurnFailure(message: message, partial: partial),
                agentID: agentID
            )
        }
    }

    @ViewBuilder
    private var turnStatus: some View {
        if let failure = turn.failure {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("room.turn.error")
                    Spacer(minLength: 8)
                    Button("重试") {
                        Task { await model.retryTurn() }
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("room.turn.retry")
                }
                if let partial = failure.partial {
                    Text(partial)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityIdentifier("room.turn.partial")
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
        } else if let banner = turn.banner {
            HStack(spacing: 8) {
                Image(systemName: banner.icon)
                    .foregroundStyle(banner.tint)
                Text(banner.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(banner.identifier)
                Spacer()
                switch model.turnState {
                case .completed, .passed, .roundCompleted:
                    Button("关闭") { model.dismissTurnError() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("room.turn.dismiss")
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if room.messages.isEmpty && turn.draft == nil {
                        emptyState
                    } else {
                        ForEach(room.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                        if let draft = turn.draft {
                            StreamingMessageRow(name: draft.agentName, text: draft.text)
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
            .onChange(of: turn.draft?.text ?? "") { _, _ in
                guard turn.draft != nil else { return }
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
            Text("配置 Provider 后开始第一轮，由系统依次邀请三位 Agent 发言；也可以播放 Mock 事件。")
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
                Task { await model.runFirstRound() }
            } label: {
                HStack(spacing: 6) {
                    if model.isFirstRoundRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("开始第一轮", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isFirstRoundRunning
                    || model.turnState.isBusy
                    || !model.hasConfiguredProvider
            )
            .accessibilityIdentifier("room.round.start")

            Button {
                Task { await model.runMockRound() }
            } label: {
                Label("Mock", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isMockRunning || model.isFirstRoundRunning)
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
