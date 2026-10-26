import Photos
import RoundtableCore
import SwiftUI
import UIKit

struct RoundSummaryPanel: View {
    @Environment(AppModel.self) private var model
    let room: RoundtableRoomModel

    @State private var showingCard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let summary = room.summary {
                if summary.degraded {
                    Label(
                        "模型总结不可用，已使用规则化降级总结",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("summary.degraded")
                }
                SummaryCategoryView(
                    title: "共识",
                    icon: "hand.thumbsup",
                    tint: .green,
                    items: summary.consensus,
                    messages: room.messages
                )
                SummaryCategoryView(
                    title: "分歧",
                    icon: "arrow.left.and.right",
                    tint: .red,
                    items: summary.dissent,
                    messages: room.messages
                )
                SummaryCategoryView(
                    title: "建议",
                    icon: "arrow.forward.circle",
                    tint: .blue,
                    items: summary.recommendations,
                    messages: room.messages
                )
                SummaryCategoryView(
                    title: "未决问题",
                    icon: "questionmark.circle",
                    tint: .orange,
                    items: summary.unresolved,
                    messages: room.messages
                )
                if !summary.hasContent {
                    Text("这轮讨论没有形成可引用的有效观点。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if room.status == .summarizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(
                        model.summaryState == .generating
                            ? "正在整理共识、分歧与建议…"
                            : "等待生成结论"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("summary.generating")
            }

            if let error = model.summaryError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("summary.error")
            }

            if room.summary != nil {
                HStack(spacing: 10) {
                    Button {
                        showingCard = true
                    } label: {
                        Label("结论卡", systemImage: "rectangle.portrait")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("summary.card.open")

                    Button {
                        model.regenerateSummary()
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.summaryState == .generating)
                    .accessibilityIdentifier("summary.regenerate")
                }
            } else if room.status == .summarizing {
                Button {
                    model.startSummaryGenerationIfNeeded()
                } label: {
                    Label(
                        model.summaryState == .generating ? "生成中" : "生成结论",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.summaryState == .generating)
                .accessibilityIdentifier("summary.generate")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.15))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $showingCard) {
            if let summary = room.summary, let snapshot = room.snapshot {
                SummaryCardPreview(
                    topic: snapshot.topic,
                    participants: room.participants,
                    messages: room.messages,
                    summary: summary
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(.blue)
            Text("圆桌结论")
                .font(.headline)
            Spacer()
            if let summary = room.summary {
                Text("v\(summary.version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SummaryCategoryView: View {
    let title: String
    let icon: String
    let tint: Color
    let items: [SummaryItem]
    let messages: [Message]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            if items.isEmpty {
                Text("暂无")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.text)
                            .font(.subheadline)
                        ForEach(item.referenceMessageIds, id: \.self) { id in
                            if let source = messages.first(where: { $0.id == id }) {
                                Label(
                                    "\(source.author.name)：\(source.claim ?? source.body)",
                                    systemImage: "quote.opening"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .accessibilityIdentifier("summary.section.\(title)")
    }
}

struct CompletedRoomBar: View {
    @Environment(AppModel.self) private var model
    let room: RoundtableRoomModel

    @State private var topic = ""

    var body: some View {
        VStack(spacing: 10) {
            TextField("基于原结论继续追问…", text: $topic, axis: .vertical)
                .lineLimit(1 ... 3)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("follow-up.topic")
            HStack {
                Text("已完成圆桌只读，追问会创建新圆桌。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        await model.createFollowUp(topic: topic)
                        if model.summaryError == nil {
                            topic = ""
                        }
                    }
                } label: {
                    if model.isCreatingFollowUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("继续追问", systemImage: "arrow.turn.down.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isCreatingFollowUp
                        || room.summary == nil
                )
                .accessibilityIdentifier("follow-up.create")
            }
            if let error = model.summaryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
    }
}

private struct SummaryCardPreview: View {
    let topic: String
    let participants: [Participant]
    let messages: [Message]
    let summary: RoundSummary

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var showingShare = false
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                            .accessibilityIdentifier("summary.card.preview")
                    } else {
                        ProgressView("正在生成结论卡…")
                            .frame(maxWidth: .infinity, minHeight: 420)
                    }
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("结论卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        saveToPhotos()
                    } label: {
                        Label("保存相册", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("summary.card.save")
                    Spacer()
                    Button {
                        showingShare = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("summary.card.share")
                }
            }
            .task {
                image = SummaryCardRenderer.image(
                    topic: topic,
                    participants: participants,
                    messages: messages,
                    summary: summary
                )
            }
            .sheet(isPresented: $showingShare) {
                if let image {
                    ActivityView(items: [image])
                }
            }
        }
    }

    private func saveToPhotos() {
        guard let image else { return }
        Task {
            do {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    saveMessage = "没有相册写入权限，请在系统设置中允许。"
                    return
                }
                try await PhotoLibraryWriter.save(image)
                saveMessage = "结论卡已保存到相册。"
            } catch {
                saveMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor
enum SummaryCardRenderer {
    static func image(
        topic: String,
        participants: [Participant],
        messages: [Message],
        summary: RoundSummary
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: SummaryCardView(
                topic: topic,
                participants: participants,
                messages: messages,
                summary: summary
            )
            .frame(width: 1080, height: 1350)
        )
        renderer.scale = 1
        return renderer.uiImage
    }
}

private struct SummaryCardView: View {
    let topic: String
    let participants: [Participant]
    let messages: [Message]
    let summary: RoundSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Label("AI 圆桌", systemImage: "person.3.fill")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
                Text(summary.degraded ? "降级总结" : "结构化结论")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            summary.degraded
                                ? Color.orange.opacity(0.14)
                                : Color.blue.opacity(0.12)
                        )
                    )
            }

            Text(topic)
                .font(.system(size: 48, weight: .bold))
                .lineLimit(3)
                .minimumScaleFactor(0.7)

            HStack(spacing: 18) {
                ForEach(participants) { participant in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(participant.agent.name)
                            .font(.system(size: 28, weight: .bold))
                        Text(primaryClaim(for: participant))
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color.white.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            cardSection("共识", items: summary.consensus, tint: .green)
            cardSection("分歧", items: summary.dissent, tint: .red)
            cardSection("建议", items: summary.recommendations, tint: .blue)
            Spacer(minLength: 0)
            Text("所有参与者均为 AI · 结论仅基于圆桌中的引用观点")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
        .padding(64)
        .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.2))
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.97, blue: 0.94),
                    Color(red: 0.92, green: 0.95, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func primaryClaim(for participant: Participant) -> String {
        messages
            .last {
                $0.author.roundtableAgentId == participant.id
                    && !($0.claim ?? $0.body).isEmpty
            }
            .map { $0.claim ?? $0.body }
            ?? participant.agent.tagline
    }

    @ViewBuilder
    private func cardSection(
        _ title: String,
        items: [SummaryItem],
        tint: Color
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(tint)
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(tint)
                            .frame(width: 10, height: 10)
                            .padding(.top, 10)
                        Text(item.text)
                            .font(.system(size: 26))
                            .lineLimit(3)
                    }
                }
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum PhotoLibraryWriter {
    static func save(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? CocoaError(.fileWriteUnknown)
                    )
                }
            }
        }
    }
}
