import Foundation
import RoundtableCore

struct RoundtableHistoryEntry: Identifiable, Equatable {
    let snapshot: RoundtableSnapshot
    let cachedState: StoredRoomState?

    var id: UUID { snapshot.id }
    var isCached: Bool { cachedState != nil }

    var statusLabel: String {
        switch snapshot.status {
        case .ready: "待开始"
        case .running: "讨论中"
        case .paused: "已暂停"
        case .summarizing: "生成结论"
        case .completed: "已完成"
        case .failed: "失败"
        case .archived: "已归档"
        case .draft, .unknown: "未知状态"
        }
    }
}
