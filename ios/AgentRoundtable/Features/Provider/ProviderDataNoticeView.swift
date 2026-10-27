import SwiftUI

struct ProviderDataNoticeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("第三方模型服务", systemImage: "network.badge.shield.half.filled")
                        .font(.title2.bold())
                        .accessibilityIdentifier("provider.dataNotice.title")

                    Text("调用真实模型时，议题、对话消息和总结请求会从本机直接发送给你选择的 Provider。圆桌后端不会收到 API Key。")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "Provider 可能按其隐私政策处理这些内容。",
                            systemImage: "building.2"
                        )
                        Label("API Key 只保存在本机 Keychain。", systemImage: "key.horizontal")
                        Label("本地规则会在发送前检查明显危险内容。", systemImage: "checkmark.shield")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text("确认状态只保存在 UserDefaults；不会保存 API Key。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("provider.dataNotice.storage")
                }
                .padding(20)
            }
            .navigationTitle("数据发送提示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.declineProviderDataNotice()
                        dismiss()
                    }
                    .accessibilityIdentifier("provider.dataNotice.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") {
                        model.confirmProviderDataNotice()
                        dismiss()
                    }
                    .accessibilityIdentifier("provider.dataNotice.confirm")
                }
            }
        }
    }
}
