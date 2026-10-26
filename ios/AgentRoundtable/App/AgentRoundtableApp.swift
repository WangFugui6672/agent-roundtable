import SwiftUI

@main
struct AgentRoundtableApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.enterForeground()
                    } else {
                        model.enterBackground()
                    }
                }
        }
    }
}
