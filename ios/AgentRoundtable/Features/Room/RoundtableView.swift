import RoundtableCore
import SwiftUI

struct RoundtableView: View {
    @Environment(AppModel.self) private var model
    let room: RoundtableRoomModel
    @State private var visibleMessageID: UUID?
    @State private var showingHiddenMessages = false
    @State private var showingPrivacy = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            RoomHeader(
                room: room,
                statusText: statusBadge.text,
                statusTint: statusBadge.tint,
                streamText: streamBadge.text,
                streamTint: streamBadge.tint,
                contentSafetyNotice: model.contentSafetyNotice,
                contentSafetyError: model.contentSafetyError,
                controlError: room.status == .completed ? model.controlError : nil
            )
            Divider()
            RoomParticipantsStrip(
                participants: room.participants,
                activeAgentID: room.activeParticipantId ?? turn.agentID
            )
            Divider()
            turnStatus
            messageList
            Divider()
            if room.status == .completed {
                CompletedRoomBar(room: room)
            } else if room.status != .summarizing {
                UserControlBar(room: room)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("圆桌")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingPrivacy = true
                } label: {
                    Image(systemName: "hand.raised")
                }
                .accessibilityLabel("隐私与安全")
                .accessibilityIdentifier("room.privacy")

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.isDeletingRoom)
                .accessibilityLabel("删除圆桌")
                .accessibilityIdentifier("room.delete")

                Button("离开") { model.leaveRoom() }
            }
        }
        .onAppear {
            model.startSummaryGenerationIfNeeded()
        }
        .onChange(of: room.status) {
            model.startSummaryGenerationIfNeeded()
        }
        .sheet(isPresented: $showingPrivacy) {
            PrivacySafetyView()
        }
        .confirmationDialog(
            "删除这桌讨论？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除圆桌和本机缓存", role: .destructive) {
                Task { await model.deleteCurrentRoom() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "服务端消息、事件、结论与举报会立即删除；本机隐藏状态和恢复游标也会清除。"
                    + "Keychain 中的 API Key 会保留。"
            )
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
            let agentName = room.participants.first(where: { $0.id == id })?.agent.name ?? "Agent"
            return "AI · \(agentName)"
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
                    if !room.hiddenMessageIDs.isEmpty {
                        Button {
                            showingHiddenMessages.toggle()
                        } label: {
                            Label(
                                showingHiddenMessages
                                    ? "收起本地隐藏消息"
                                    : "本机已隐藏 \(room.hiddenMessageIDs.count) 条消息",
                                systemImage: showingHiddenMessages ? "eye.slash" : "eye"
                            )
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("room.hidden.toggle")
                    }
                    if room.messages.isEmpty,
                       room.failures.isEmpty,
                       turn.draft == nil,
                       room.summary == nil,
                       room.status != .summarizing {
                        emptyState
                    } else {
                        ForEach(visibleMessages) { message in
                            MessageRow(
                                message: message,
                                messages: room.messages,
                                participants: room.participants,
                                isHidden: room.hiddenMessageIDs.contains(message.id),
                                isFlagged: room.flaggedMessageIDs.contains(message.id),
                                isReported: room.reportedMessageIDs.contains(message.id)
                            )
                                .id(message.id)
                        }
                        ForEach(room.failures) { failure in
                            TurnFailureRow(failure: failure)
                                .id("room.failure.\(failure.turnId)")
                        }
                        if room.summary != nil || room.status == .summarizing {
                            RoundSummaryPanel(room: room)
                                .id("room.summary")
                        }
                        if let draft = turn.draft {
                            StreamingMessageRow(name: draft.agentName, text: draft.text)
                                .id("room.turn.draft")
                        }
                    }
                }
                .padding(16)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $visibleMessageID)
            .onAppear {
                visibleMessageID = room.lastVisibleMessageID ?? room.messages.last?.id
                scrollToVisibleMessage(using: proxy, animated: false)
            }
            .onChange(of: visibleMessageID) { _, messageID in
                guard let messageID else { return }
                model.markVisibleMessage(messageID)
            }
            .onChange(of: room.messages.count) { _, _ in
                guard let last = room.messages.last else { return }
                visibleMessageID = last.id
                scrollToVisibleMessage(using: proxy, animated: true)
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

}

private extension RoundtableView {
    var visibleMessages: [Message] {
        if showingHiddenMessages {
            return room.messages
        }
        return room.messages.filter { !room.hiddenMessageIDs.contains($0.id) }
    }

    func scrollToVisibleMessage(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let visibleMessageID else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(visibleMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(visibleMessageID, anchor: .center)
        }
    }

    var emptyState: some View {
        RoomEmptyState()
    }

    var statusBadge: (text: String, tint: Color) {
        RoomStatusPresentation.status(room: room)
    }

    var streamBadge: (text: String, tint: Color) {
        RoomStatusPresentation.stream(model.streamState)
    }
}
