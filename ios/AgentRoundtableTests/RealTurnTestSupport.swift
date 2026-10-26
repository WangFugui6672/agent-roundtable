import Foundation

import RoundtableCore

@testable import AgentRoundtable

final class TurnSecretStore: SecretStore {
    var values: [String: String] = [:]

    func secret(for account: String) throws -> String? { values[account] }
    func setSecret(_ secret: String, for account: String) throws { values[account] = secret }
    func removeSecret(for account: String) throws { values[account] = nil }
}

actor TurnLineStream: LineStreaming {
    private let statusCodes: [Int]
    private let deltasByAttempt: [[String]]
    private let usageByAttempt: [ProviderUsage?]
    private let errorAfterDeltas: Error?
    private var attempt = 0

    init(
        deltasByAttempt: [[String]],
        usageByAttempt: [ProviderUsage?] = [],
        statusCodes: [Int] = [200],
        errorAfterDeltas: Error? = nil
    ) {
        self.deltasByAttempt = deltasByAttempt
        self.usageByAttempt = usageByAttempt
        self.statusCodes = statusCodes
        self.errorAfterDeltas = errorAfterDeltas
    }

    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        let status = statusCodes[min(attempt, statusCodes.count - 1)]
        let deltas = deltasByAttempt[min(attempt, deltasByAttempt.count - 1)]
        let usage = usageByAttempt.isEmpty
            ? nil
            : usageByAttempt[min(attempt, usageByAttempt.count - 1)]
        attempt += 1
        var lines: [String] = deltas.map { delta -> String in
            let payload: [String: Any] = [
                "choices": [
                    ["delta": ["content": delta]]
                ]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return "data: \(String(data: data, encoding: .utf8) ?? "")"
        }
        if let usage {
            let usagePayload: [String: Any] = [
                "prompt_tokens": usage.inputTokens ?? NSNull(),
                "completion_tokens": usage.outputTokens ?? NSNull(),
                "total_tokens": usage.totalTokens ?? NSNull()
            ]
            let payload: [String: Any] = [
                "choices": [],
                "usage": usagePayload
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            lines.append("data: \(String(data: data, encoding: .utf8) ?? "")")
        }
        if errorAfterDeltas == nil {
            lines.append("data: [DONE]")
        }
        let failure = errorAfterDeltas
        return StreamingResponse(
            statusCode: status,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish(throwing: failure)
            }
        )
    }

    func recordedAttemptCount() -> Int { attempt }
}

actor TurnTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(data: Data(), statusCode: 500)
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

struct TurnFixture {
    let id: UUID
    let agentID: UUID
    let position: Int
    let key: String
    let name: String

    var wire: [String: Any] { wire(round: 1) }

    func wire(round: Int) -> [String: Any] {
        [
            "turn_id": id.uuidString,
            "round": round,
            "roundtable_agent_id": agentID.uuidString,
            "position": position,
            "agent_key": key,
            "agent_name": name
        ]
    }
}

struct ReplyFixture {
    let messageType: String
    let stance: String?
    let claim: String
    let body: String
    let sequence: Int
    let messageID: UUID
    let roundNumber: Int
    let references: [UUID]
    let challengeTargetAgentID: UUID?

    init(
        messageType: String,
        stance: String?,
        claim: String,
        body: String,
        sequence: Int,
        messageID: UUID = UUID(),
        roundNumber: Int = 1,
        references: [UUID] = [],
        challengeTargetAgentID: UUID? = nil
    ) {
        self.messageType = messageType
        self.stance = stance
        self.claim = claim
        self.body = body
        self.sequence = sequence
        self.messageID = messageID
        self.roundNumber = roundNumber
        self.references = references
        self.challengeTargetAgentID = challengeTargetAgentID
    }
}
