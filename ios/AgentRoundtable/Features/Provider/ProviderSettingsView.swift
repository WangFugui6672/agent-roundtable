import RoundtableCore
import SwiftUI

/// Provider settings (Issue #3). The API key field is write-only: the stored
/// key is never read back into a text field, so it cannot leak through the UI
/// or screenshots.
struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ProviderKind
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case baseURL
        case model
        case apiKey
    }

    init(initialKind: ProviderKind) {
        _kind = State(initialValue: initialKind)
    }

    private var isConfigured: Bool {
        app.isProviderConfigured(kind)
    }

    /// A leftover configuration may exist without its key (device restore), and
    /// it must still be deletable so the user can return to the Mock demo.
    private var hasConfiguration: Bool {
        app.providerConfiguration(for: kind) != nil
    }

    private var canSave: Bool {
        !app.isSavingProvider
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    providerPicker
                    fields
                    status
                    actions
                    privacyNote
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("模型 Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("provider.done")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focusedField = nil }
                        .accessibilityIdentifier("provider.dismissKeyboard")
                }
            }
            .task { loadFields() }
            .onChange(of: kind) { _, _ in
                app.clearProviderFeedback()
                loadFields()
            }
            .confirmationDialog(
                "删除 \(kind.displayName) 的配置和 API Key？",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    app.deleteProvider(kind)
                    loadFields()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("API Key 会从 Keychain 中移除，此操作不可撤销。")
            }
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择 Provider")
                .font(.headline)

            Picker("Provider", selection: $kind) {
                ForEach(ProviderKind.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("provider.kind")

            Text(kind.isCustom
                 ? "填写任意 OpenAI-compatible 服务的 BaseURL 与模型名。"
                 : "使用 \(kind.displayName) 的 OpenAI-compatible 接口。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup("BaseURL") {
                TextField("https://…/v1", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .baseURL)
                    .providerFieldStyle()
                    .accessibilityIdentifier("provider.baseURL")
            }

            fieldGroup("Model") {
                TextField("例如 qwen-plus", text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)
                    .providerFieldStyle()
                    .accessibilityIdentifier("provider.model")
            }

            fieldGroup("API Key") {
                SecureField(isConfigured ? "已保存在 Keychain，留空则不修改" : "sk-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .apiKey)
                    .providerFieldStyle()
                    .accessibilityIdentifier("provider.apiKey")
                Text("Key 只保存在本机 Keychain，不会上传到圆桌后端。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fieldGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = app.providerError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("provider.error")
            }
            if let message = app.providerCheckMessage {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("provider.checkResult")
            }
            if isConfigured {
                Label("已保存到 Keychain", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("provider.status")
            } else if hasConfiguration {
                Label("API Key 已丢失，请重新输入后保存。", systemImage: "key.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("provider.missingKey")
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if app.saveProvider(
                    ProviderDraft(kind: kind, baseURL: baseURL, model: modelName, apiKey: apiKey)
                ) {
                    apiKey = ""
                }
            } label: {
                Text(app.isSavingProvider ? "正在保存…" : "保存")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .accessibilityIdentifier("provider.save")

            Button {
                Task {
                    await app.checkProvider(
                        ProviderDraft(kind: kind, baseURL: baseURL, model: modelName, apiKey: apiKey)
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    if app.isCheckingProvider {
                        ProgressView().controlSize(.small)
                    }
                    Text(app.isCheckingProvider ? "正在验证…" : "验证连接")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(app.isCheckingProvider || !canSave)
            .accessibilityIdentifier("provider.check")

            if hasConfiguration {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text("删除此 Provider")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .accessibilityIdentifier("provider.delete")
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("议题和消息会直接发送给你选择的模型服务商，不经过圆桌后端。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("换设备或重装 App 后需要重新输入 API Key。", systemImage: "iphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadFields() {
        let existing = app.providerConfiguration(for: kind)
        baseURL = existing?.baseURL ?? kind.defaultBaseURL
        modelName = existing?.model ?? kind.defaultModel
        apiKey = ""
    }
}

#Preview {
    ProviderSettingsView(initialKind: .deepseek)
        .environment(AppModel())
}

private extension View {
    /// Shared look for the three provider inputs.
    func providerFieldStyle() -> some View {
        padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}
