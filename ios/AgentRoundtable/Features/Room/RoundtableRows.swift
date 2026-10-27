import RoundtableCore
import SwiftUI

struct TurnFailureRow: View {
    let failure: TurnFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("AI · \(failure.agentName) 未能完成本轮")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(failure.retryable ? "可重试" : "不可重试")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            failure.retryable
                                ? Color.orange.opacity(0.14)
                                : Color.red.opacity(0.12)
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
            "AI 参与者 \(failure.agentName) 失败，\(failure.failureCode)，"
                + (failure.retryable ? "可重试" : "不可重试")
        )
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
            Text("AI 正在输入")
                .font(.caption2)
                .foregroundStyle(.blue)
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
