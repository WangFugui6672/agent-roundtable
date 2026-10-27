import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPrivacy = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("让三种立场把一个问题讨论清楚")
                        .font(.title2.bold())
                    Text("两轮引用式讨论，最后收敛为可追溯的共识、分歧与建议。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                Button {
                    model.isCreatingRoundtable = true
                } label: {
                    Label("新建圆桌", systemImage: "plus.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home.create")
            }

            Section("历史圆桌") {
                if model.historyEntries.isEmpty {
                    ContentUnavailableView(
                        "还没有圆桌",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("创建第一场讨论后会显示在这里。")
                    )
                } else {
                    ForEach(model.historyEntries) { entry in
                        Button {
                            Task { await model.openHistory(entry) }
                        } label: {
                            historyRow(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task { await model.deleteHistory(entry) }
                            }
                        }
                        .accessibilityIdentifier("home.room.\(entry.id.uuidString)")
                    }
                }
            }

            if let error = model.historyError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("圆桌")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPrivacy = true
                } label: {
                    Image(systemName: "hand.raised")
                }
                .accessibilityLabel("隐私与安全")
                .accessibilityIdentifier("home.privacy")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新历史")
                .accessibilityIdentifier("home.refresh")
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            PrivacySafetyView()
        }
        .task {
            if model.historyEntries.isEmpty {
                await model.refreshHistory()
            }
        }
    }

    private func historyRow(_ entry: RoundtableHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.snapshot.topic)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(entry.statusLabel)
                if entry.isCached {
                    Label("本机可离线阅读", systemImage: "internaldrive")
                }
                Spacer()
                Text(entry.snapshot.updatedAt, format: .dateTime.month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
