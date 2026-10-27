import Foundation
import RoundtableCore

extension AppModel {
    func reloadCachedHistory() {
        let cached = (try? repository.loadCachedRooms()) ?? []
        mergeHistory(cached: cached, remote: historyEntries.map(\.snapshot))
    }

    func refreshHistory() async {
        do {
            let remote = try await repository.fetchHistory()
            let cached = try repository.loadCachedRooms()
            mergeHistory(cached: cached, remote: remote)
            historyError = nil
        } catch {
            historyError = "历史同步失败，正在显示本机记录：\(Self.userMessage(for: error))"
        }
    }

    func openHistory(_ entry: RoundtableHistoryEntry) async {
        do {
            if try repository.restore(roomID: entry.id) {
                isRoomPresented = true
            } else {
                let snapshot = try await repository.fetchRoundtable(id: entry.id)
                try repository.present(snapshot)
                isRoomPresented = true
            }
            if let guestSessionID {
                repository.connect(guestSessionID: guestSessionID)
            }
            historyError = nil
        } catch {
            historyError = "打开圆桌失败：\(Self.userMessage(for: error))"
        }
    }

    func deleteHistory(_ entry: RoundtableHistoryEntry) async {
        guard !isDeletingHistory else { return }
        isDeletingHistory = true
        defer { isDeletingHistory = false }
        do {
            try await repository.deleteRoundtable(roomID: entry.id)
            historyEntries.removeAll { $0.id == entry.id }
            if room?.snapshot?.id == entry.id {
                resetAfterRoomDeletion()
                isRoomPresented = false
            }
            historyError = nil
        } catch {
            historyError = "删除圆桌失败：\(Self.userMessage(for: error))"
        }
    }

    private func mergeHistory(
        cached: [StoredRoomState],
        remote: [RoundtableSnapshot]
    ) {
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map {
            ($0.snapshot.id, $0)
        })
        var seen: Set<UUID> = []
        var merged: [RoundtableHistoryEntry] = []
        for snapshot in remote where seen.insert(snapshot.id).inserted {
            merged.append(
                RoundtableHistoryEntry(
                    snapshot: snapshot,
                    cachedState: cachedByID[snapshot.id]
                )
            )
        }
        for state in cached where seen.insert(state.snapshot.id).inserted {
            merged.append(
                RoundtableHistoryEntry(snapshot: state.snapshot, cachedState: state)
            )
        }
        historyEntries = merged
    }
}
