import Foundation
import RoundtableCore
import SwiftData

extension AppModel {
    static var defaultBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["RT_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "RTAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }

    static func live() -> AppModel {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let storeURL = directory.appendingPathComponent("AgentRoundtable.store")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            #if DEBUG
            if ProcessInfo.processInfo.environment["RT_RESET_PERSISTED_ROOM"] == "1" {
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(
                        atPath: storeURL.path + suffix
                    )
                }
            }
            #endif
            let store = try SwiftDataRoomStore(storeURL: storeURL)
            return AppModel(roomStore: store)
        } catch {
            return AppModel()
        }
    }

    static func mapConnectionState(
        _ state: RoundtableConnectionState
    ) -> StreamState {
        switch state {
        case .idle: return .idle
        case .connecting: return .connecting
        case .connected: return .connected
        case let .waitingToReconnect(attempt, _): return .reconnecting(attempt: attempt)
        case let .disconnected(message):
            if let message {
                return .failed(message)
            }
            return .closed
        }
    }

    /// Provider errors already carry actionable text, so they win over fallback copy.
    static func userMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.message
        }
        if let validation = error as? ProviderValidationError {
            return validation.message
        }
        if let keychain = error as? KeychainError {
            return keychain.message
        }
        if let apiError = error as? APIError {
            return apiError.message
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络请求失败：\(nsError.localizedDescription)"
        }
        return error.localizedDescription
    }
}
