import RoundtableCore
import SwiftUI

struct StatusPill: View {
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

struct RoomHeader: View {
    let room: RoundtableRoomModel
    let statusText: String
    let statusTint: Color
    let streamText: String
    let streamTint: Color
    let contentSafetyNotice: String?
    let contentSafetyError: String?
    let controlError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(room.snapshot?.topic ?? "")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                StatusPill(text: statusText, tint: statusTint)
                StatusPill(text: streamText, tint: streamTint)
                Spacer()
                Text("第 \(room.currentRound)/\(room.snapshot?.maxRounds ?? 2) 轮")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            budget
            notices
        }
        .padding(16)
    }

    @ViewBuilder
    private var budget: some View {
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

    @ViewBuilder
    private var notices: some View {
        if let notice = contentSafetyNotice {
            Label(notice, systemImage: "flag")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("room.content.notice")
        } else if let error = contentSafetyError {
            Label(error, systemImage: "hand.raised.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .accessibilityIdentifier("room.content.blocked")
        }
        if let controlError {
            Label(controlError, systemImage: "trash.slash")
                .font(.caption2)
                .foregroundStyle(.red)
                .accessibilityIdentifier("room.delete.error")
        }
    }
}

struct RoomParticipantsStrip: View {
    let participants: [Participant]
    let activeAgentID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(participants) { participant in
                    ParticipantChip(
                        participant: participant,
                        isActive: activeAgentID == participant.id
                    )
                    .accessibilityIdentifier("room.participant.\(participant.position)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct RoomEmptyState: View {
    var body: some View {
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
}

@MainActor
enum RoomStatusPresentation {
    static func status(room: RoundtableRoomModel) -> (text: String, tint: Color) {
        if room.budgetExhaustion != nil {
            return ("预算用尽", .orange)
        }
        if room.pausePending {
            return ("将在当前发言后暂停", .orange)
        }
        return statusPresentation(room.status)
    }

    private static func statusPresentation(
        _ status: RoundtableStatus?
    ) -> (text: String, tint: Color) {
        guard let status else { return ("准备中", .secondary) }
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

    static func stream(_ state: AppModel.StreamState) -> (text: String, tint: Color) {
        switch state {
        case .idle: return ("未连接", .secondary)
        case .connecting: return ("连接中", .orange)
        case .connected: return ("已连接", .green)
        case .reconnecting: return ("离线，重试中", .orange)
        case .closed: return ("已断开", .secondary)
        case .failed: return ("连接失败", .red)
        }
    }
}

struct ParticipantChip: View {
    let participant: Participant
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            Text(participant.agent.name)
                .font(.subheadline.weight(.medium))
            Text("AI")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
                .foregroundStyle(.blue)
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
        .accessibilityLabel("AI 参与者 \(participant.agent.name)，\(stateText)")
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
        case .passed: "已查看但不发言"
        case .completed: "已发言"
        case .failed: "失败"
        case .unknown: "—"
        }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let messages: [Message]
    let participants: [Participant]
    let isHidden: Bool
    let isFlagged: Bool
    let isReported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(message.author.name)
                    .font(.subheadline.weight(.semibold))
                if message.author.type == .user {
                    Text("用户")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("AI")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                        .foregroundStyle(.blue)
                    StanceBadge(messageType: message.messageType, stance: message.stance)
                }
                Spacer()
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if message.author.type == .agent {
                    Menu {
                        Menu("举报") {
                            ForEach(MessageReportReason.allCases, id: \.self) { reason in
                                Button(reason.displayName) {
                                    Task {
                                        await model.reportMessage(message.id, reason: reason)
                                    }
                                }
                            }
                        }
                        Button(isHidden ? "取消本地隐藏" : "仅在本机隐藏") {
                            if isHidden {
                                model.showMessage(message.id)
                            } else {
                                model.hideMessage(message.id)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("消息操作")
                    .accessibilityIdentifier("room.message.menu")
                }
            }

            if isHidden || isFlagged || isReported {
                HStack(spacing: 6) {
                    if isHidden {
                        Label("本地隐藏", systemImage: "eye.slash")
                    }
                    if isFlagged {
                        Label("本地规则标记，未经审核", systemImage: "flag")
                    }
                    if isReported {
                        Label("已举报", systemImage: "checkmark.circle")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if let claim = message.claim, !claim.isEmpty {
                Text(claim)
                    .font(.body.weight(.medium))
            }

            Text(message.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !message.mentionedAgentIds.isEmpty {
                Label(
                    "点名 \(message.mentionedAgentIds.count) 位 Agent",
                    systemImage: "at"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            if let challengeTargetName {
                Label(
                    "向 \(challengeTargetName) 提出\(stanceLabel)",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("room.message.challenge-target")
            }

            ForEach(referencedMessages) { reference in
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "引用 AI · \(reference.author.name) 的原观点",
                        systemImage: "quote.opening"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Text(reference.claim ?? reference.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(stanceTint.opacity(0.55))
                        .frame(width: 3)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    message.author.type == .user
                        ? Color.accentColor.opacity(0.08)
                        : Color(.secondarySystemGroupedBackground)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("room.message.\(message.id.uuidString)")
    }

    private var referencedMessages: [Message] {
        message.references.compactMap { referenceID in
            messages.first(where: { $0.id == referenceID })
        }
    }

    private var challengeTargetName: String? {
        guard let targetID = message.challengeTargetAgentId else { return nil }
        return participants.first(where: { $0.id == targetID })?.agent.name
    }

    private var stanceLabel: String {
        switch message.stance {
        case .support: "支持"
        case .challenge: "质疑"
        case .supplement: "补充"
        case .question: "追问"
        case .unknown, .none:
            message.messageType == .proposal ? "提议" : "发言"
        }
    }

    private var stanceTint: Color {
        switch message.stance {
        case .support: .green
        case .challenge: .red
        case .supplement: .blue
        case .question: .orange
        case .unknown, .none: .secondary
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            message.author.type == .agent
                ? "AI 参与者 \(message.author.name)，\(stanceLabel)"
                : "\(message.author.name)，\(stanceLabel)",
            message.claim ?? message.body,
            message.body
        ]
        if let challengeTargetName {
            parts.append("向 \(challengeTargetName) 提出\(stanceLabel)")
        }
        for reference in referencedMessages {
            parts.append(
                "引用 AI 参与者 \(reference.author.name) 的原观点："
                    + "\(reference.claim ?? reference.body)"
            )
        }
        return parts.joined(separator: "。")
    }
}

struct StanceBadge: View {
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
        case .userMessage: return ("用户", .secondary)
        default: return ("发言", .secondary)
        }
    }
}
