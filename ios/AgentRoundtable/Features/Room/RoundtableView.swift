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
            UserControlBar(room: room)
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

            if let budget = room.snapshot?.budget {
                Text(
                    "\(budget.agentMessagesUsed)/\(budget.maxAgentMessages) 条 · "
                        + "\(budget.reportedTokens)/\(budget.maxReportedTokens) Token（本机上报） · "
                        + "\(budget.elapsedSeconds)/\(budget.maxDurationSeconds) 秒"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("room.budget")
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
        case .paused:
            return TurnPresentation(
                banner: TurnBanner(
                    text: "讨论已暂停",
                    icon: "pause.circle",
                    tint: .orange,
                    identifier: "room.paused"
                )
            )
        case .ended:
            return TurnPresentation(
                banner: TurnBanner(
                    text: "讨论已结束",
                    icon: "stop.circle",
                    tint: .blue,
                    identifier: "room.ended"
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
        if let exhaustion = room.budgetExhaustion {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .foregroundStyle(.orange)
                Text(exhaustion.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("room.budget.exhausted")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else if let failure = turn.failure {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("room.turn.error")
                    Spacer(minLength: 8)
                    if model.failureRetryable {
                        Button("继续") {
                            Task { await model.retryTurn() }
                        }
                        .font(.footnote)
                        .accessibilityIdentifier("room.turn.retry")
                    }
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
                case .completed, .passed, .roundCompleted, .paused, .ended:
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
                    if room.messages.isEmpty && room.failures.isEmpty && turn.draft == nil {
                        emptyState
                    } else {
                        ForEach(room.messages) { message in
                            MessageRow(
                                message: message,
                                messages: room.messages,
                                participants: room.participants
                            )
                                .id(message.id)
                        }
                        ForEach(room.failures) { failure in
                            TurnFailureRow(failure: failure)
                                .id("room.failure.\(failure.turnId)")
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
            .onChange(of: room.failures.count) { _, _ in
                guard let last = room.failures.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("room.failure.\(last.turnId)", anchor: .bottom)
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

    private var statusBadge: (text: String, tint: Color) {
        guard let status = room.status else { return ("准备中", .secondary) }
        if room.budgetExhaustion != nil {
            return ("预算用尽", .orange)
        }
        if room.pausePending {
            return ("将在当前发言后暂停", .orange)
        }
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

private struct TurnFailureRow: View {
    let failure: TurnFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("\(failure.agentName) 未能完成本轮")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(failure.retryable ? "可重试" : "不可重试")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            failure.retryable ? Color.orange.opacity(0.14) : Color.red.opacity(0.12)
                        )
                    )
                    .foregroundStyle(failure.retryable ? .orange : .red)
            }
            Text(failure.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let partial = failure.partial, !partial.isEmpty {
                Text(partial)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(failure.failureCode)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.red.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.16))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("room.failure.\(failure.turnId.uuidString)")
        .accessibilityLabel(
            "\(failure.agentName) 失败，\(failure.failureCode)，"
                + (failure.retryable ? "可重试" : "不可重试")
        )
    }
}
