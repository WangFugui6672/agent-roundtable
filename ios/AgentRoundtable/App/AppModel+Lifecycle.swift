import Foundation

extension AppModel {
    func enterBackground() {
        isSceneActive = false
        let shouldPause = generationTask != nil
            || summaryTask != nil
            || isFirstRoundRunning
            || turnState.isBusy
            || summaryState.isBusy
            || room?.activeTurn != nil
            || room?.status == .running
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        summaryTask?.cancel()
        summaryTask = nil
        summaryGenerationID = nil
        isFirstRoundRunning = false
        scheduledTurn = nil
        if shouldPause {
            switch turnState {
            case .failed, .completed, .passed, .roundCompleted, .ended:
                break
            default:
                turnState = .paused
            }
            if summaryState.isBusy {
                summaryState = .paused
            }
        }
        repository.disconnect(reason: "App 已进入后台，连接已暂停。")
        guard shouldPause else { return }
        Task { [weak self] in
            await self?.pauseDiscussion()
        }
    }

    func enterForeground() {
        isSceneActive = true
        guard phase == .ready,
              let guestSessionID,
              repository.room != nil else { return }
        repository.connect(guestSessionID: guestSessionID)
    }
}
