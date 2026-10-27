import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .animation(.easeInOut(duration: 0.2), value: model.phase)
        }
        .sheet(isPresented: Bindable(model).isProviderDataNoticePresented) {
            ProviderDataNoticeView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在连接圆桌服务…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("无法连接", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") {
                    Task { await model.bootstrap() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            if let room = model.room {
                RoundtableView(room: room)
            } else {
                CreateRoundtableView()
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
