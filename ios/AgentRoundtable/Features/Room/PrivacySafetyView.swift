import SwiftUI

struct PrivacySafetyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingSessionDeletion = false
    @State private var showingRotation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(
                        title: "AI 标识",
                        icon: "sparkles",
                        body:
                            "参与者、消息、生成状态与结论均明确标注 AI。"
                            + "产品只提供三个固定预设 Agent，不提供公众人物冒充或公众人物克隆能力。"
                    )
                    section(
                        title: "本地内容规则",
                        icon: "checkmark.shield",
                        body:
                            "明显违法、危险、仇恨或涉及未成年人的操作性内容会在本机阻止，"
                            + "不会发送给服务端或模型服务商。较低置信度的不适宜内容会被标记但允许继续。"
                            + "标记不代表已经通过模型或人工审核。"
                    )
                    section(
                        title: "举报与隐藏",
                        icon: "flag",
                        body:
                            "举报只提交给维护者，不会自动删除或改写消息，也不产生审核结论。"
                            + "隐藏仅影响当前设备显示，服务端消息仍保留，其他设备不受影响。"
                    )
                    section(
                        title: "第三方模型服务",
                        icon: "network",
                        body:
                            "真实 Provider 首次调用前会展示数据发送提示。议题和讨论内容由本机直连"
                            + "用户选择的模型服务商；Django 不接收 API Key。"
                    )
                    section(
                        title: "90 天保留",
                        icon: "calendar.badge.clock",
                        body:
                            "圆桌、消息、事件与结论从圆桌最后一次活动起保留 90 天。"
                            + "活动包括打开房间、讨论消息、回合、控制命令和结论更新。"
                            + "到期清理会删除整桌关联数据；API Key 不参与保留清理。"
                    )
                    section(
                        title: "删除数据",
                        icon: "trash",
                        body:
                            "删除圆桌会立即清理服务端消息、事件、结论、用量、举报，以及本机缓存、"
                            + "隐藏状态和恢复游标。Keychain 中的 API Key 仅在你主动删除 Provider 时移除。"
                    )
                    section(
                        title: "匿名会话",
                        icon: "person.badge.key",
                        body:
                            "匿名会话标识由后端生成并保存在本机 Keychain（WhenUnlockedThisDeviceOnly）。"
                            + "旧版本留在 UserDefaults 的标识会在下次启动时迁移到 Keychain。"
                    )
                    sessionActions
                }
                .padding(20)
            }
            .navigationTitle("隐私与安全")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("删除匿名会话数据？", isPresented: $showingSessionDeletion) {
            Button("删除全部数据", role: .destructive) {
                Task { await model.deleteGuestSession() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务端圆桌与消息会立即删除，本机缓存和游标也会清除；Keychain 中的 Provider API Key 保留。")
        }
        .confirmationDialog(
            "轮换匿名会话标识？",
            isPresented: $showingRotation,
            titleVisibility: .visible
        ) {
            Button("轮换标识") {
                Task { await model.rotateGuestSession() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧标识会立即失效，已有圆桌继续归属于新的设备标识。")
        }
    }

    private var sessionActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.controlError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                showingRotation = true
            } label: {
                Label("轮换匿名会话标识", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(model.isManagingSession)
            .accessibilityIdentifier("privacy.session.rotate")

            Button(role: .destructive) {
                showingSessionDeletion = true
            } label: {
                Label("删除匿名会话全部数据", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(model.isManagingSession)
            .accessibilityIdentifier("privacy.session.delete")
        }
    }

    private func section(title: String, icon: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
