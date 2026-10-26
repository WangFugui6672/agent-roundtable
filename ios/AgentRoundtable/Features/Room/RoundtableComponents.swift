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

struct ParticipantChip: View {
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
        case .passed: "已查看但不发言"
        case .completed: "已发言"
        case .failed: "失败"
        case .unknown: "—"
        }
    }
}

struct MessageRow: View {
    let message: Message

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
                    StanceBadge(messageType: message.messageType, stance: message.stance)
                }
                Spacer()
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
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

            if !message.references.isEmpty {
                Label(
                    "引用了 \(message.references.count) 条观点",
                    systemImage: "arrowshape.turn.up.left"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        .accessibilityLabel(
            "\(message.author.name)：\(message.claim ?? message.body)。\(message.body)"
        )
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

struct StreamingMessageRow: View {
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
