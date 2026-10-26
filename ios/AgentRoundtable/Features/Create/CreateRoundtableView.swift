import RoundtableCore
import SwiftUI

struct CreateRoundtableView: View {
    @Environment(AppModel.self) private var model
    @State private var topic = ""
    @FocusState private var topicFocused: Bool

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        model.canStart && !trimmedTopic.isEmpty && topic.count <= 500
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                topicSection
                participantsSection
                startSection
                disclaimer
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("新建圆桌")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("把一个问题交给三位不同立场的 AI。")
                .font(.title2.bold())
            Text("他们会围绕议题讨论两轮，并各自引用对方的观点。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("议题")
                .font(.headline)

            TextField("例如：该不该把验证周期压缩到两周？", text: $topic, axis: .vertical)
                .focused($topicFocused)
                .lineLimit(3 ... 6)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .accessibilityLabel("圆桌议题")

            HStack {
                Text("越具体，讨论越容易收敛。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(topic.count)/500")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(topic.count > 500 ? .red : .secondary)
            }
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("参与者")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedProfileIDs.count)/3")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(model.profiles) { profile in
                AgentCard(
                    profile: profile,
                    isSelected: model.isSelected(profile)
                ) {
                    model.toggleSelection(profile)
                }
            }
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                topicFocused = false
                Task { await model.createRoundtable(topic: topic) }
            } label: {
                HStack(spacing: 8) {
                    if model.isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(model.isCreating ? "正在创建…" : "开始讨论")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)

            if let error = model.createError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("创建失败：\(error)")
            } else if model.selectedProfileIDs.count < 3 {
                Text("请选择 3 个参与者。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disclaimer: some View {
        Text("所有参与者均为 AI，不会冒充真人或公众人物。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private struct AgentCard: View {
    let profile: AgentProfile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(profile.name.prefix(1)))
                    .font(.title3.bold())
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color(.tertiarySystemFill)))
                    .foregroundStyle(isSelected ? .white : .primary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.name)
                            .font(.headline)
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    }
                    Text(profile.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(profile.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name)，\(profile.tagline)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        CreateRoundtableView()
            .environment(AppModel())
    }
}
