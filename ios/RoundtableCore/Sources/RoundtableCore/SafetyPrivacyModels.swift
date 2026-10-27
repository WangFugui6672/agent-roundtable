import Foundation

public enum MessageReportReason: String, Codable, CaseIterable, Hashable, Sendable {
    case harassment
    case hate
    case dangerous
    case sexual
    case impersonation
    case other

    public var displayName: String {
        switch self {
        case .harassment: "骚扰或攻击"
        case .hate: "仇恨内容"
        case .dangerous: "危险内容"
        case .sexual: "不适宜内容"
        case .impersonation: "冒充公众人物"
        case .other: "其他问题"
        }
    }
}

public enum MessageReportState: String, Codable, Sendable {
    case submitted
}

public struct MessageReportReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let messageId: UUID
    public let reason: MessageReportReason
    public let details: String
    public let state: MessageReportState
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        messageId: UUID,
        reason: MessageReportReason,
        details: String,
        state: MessageReportState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.messageId = messageId
        self.reason = reason
        self.details = details
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RoundtableDeletionError: Error, LocalizedError {
    case server(Error)
    case local(Error)

    public var errorDescription: String? {
        switch self {
        case let .server(error):
            return "服务端删除失败，本机缓存未清理：\(error.localizedDescription)"
        case let .local(error):
            return "服务端已删除，但本机缓存清理失败；可以重试删除：\(error.localizedDescription)"
        }
    }
}
