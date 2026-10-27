import Foundation
import XCTest

@testable import RoundtableCore

private actor StubLineStream: LineStreaming {
    private(set) var requests: [URLRequest] = []
    private let statusCode: Int
    private let lines: [String]
    private let error: Error?

    init(statusCode: Int = 200, lines: [String] = [], error: Error? = nil) {
        self.statusCode = statusCode
        self.lines = lines
        self.error = error
    }

    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        requests.append(request)
        if let error {
            throw error
        }
        let captured = lines
        let response = StreamingResponse(
            statusCode: statusCode,
            lines: AsyncThrowingStream { continuation in
                for line in captured {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        )
        return response
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

final class ProviderChatClientTests: XCTestCase {
    private let configuration = ProviderConfiguration(
        kind: .deepseek,
        baseURL: "https://api.deepseek.com/v1",
        model: "deepseek-chat"
    )

    private func collect(
        _ client: ProviderChatClient,
        messages: [ChatMessage] = [.system("你是方案派"), .user("议题：测试")]
    ) async -> Result<[String], Error> {
        var deltas: [String] = []
        do {
            for try await delta in client.stream(
                configuration: configuration,
                apiKey: "sk-test",
                messages: messages
            ) {
                deltas.append(delta)
            }
            return .success(deltas)
        } catch {
            return .failure(error)
        }
    }

    private func collectEvents(
        _ client: ProviderChatClient,
        messages: [ChatMessage] = [.system("你是方案派"), .user("议题：测试")]
    ) async -> Result<[ProviderStreamEvent], Error> {
        var events: [ProviderStreamEvent] = []
        do {
            for try await event in client.streamEvents(
                configuration: configuration,
                apiKey: "sk-test",
                messages: messages
            ) {
                events.append(event)
            }
            return .success(events)
        } catch {
            return .failure(error)
        }
    }

    func testStreamsDeltasFromSSE() async throws {
        let transport = StubLineStream(lines: [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"你好"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"，世界"}}]}"#,
            "data: [DONE]"
        ])
        let client = ProviderChatClient(streaming: transport)

        let result = await collect(client)

        XCTAssertEqual(try result.get(), ["你好", "，世界"])
    }

    func testIgnoresCommentsAndStopsAtDone() async throws {
        let transport = StubLineStream(lines: [
            ": keep-alive",
            "event: message",
            #"data: {"choices":[{"delta":{"content":"第一段"}}]}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"不应出现"}}]}"#
        ])

        let result = await collect(ProviderChatClient(streaming: transport))

        XCTAssertEqual(try result.get(), ["第一段"])
    }

    func testParsesUsageAndFinishReasonFromSSE() async throws {
        let transport = StubLineStream(lines: [
            #"data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}],"usage":null}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"# +
                #""completion_tokens":4,"total_tokens":16}}"#,
            "data: [DONE]"
        ])
        let client = ProviderChatClient(streaming: transport)

        let result = await collectEvents(client)

        XCTAssertEqual(
            try result.get(),
            [
                .delta("你好"),
                .usage(ProviderUsage(inputTokens: 12, outputTokens: 4, totalTokens: 16)),
                .completed(finishReason: "stop")
            ]
        )
    }

    func testRequestTargetsChatCompletionsWithStreaming() async throws {
        let transport = StubLineStream(lines: ["data: [DONE]"])
        let client = ProviderChatClient(streaming: transport)

        _ = await collect(client)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-chat")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
    }

    func testUnauthorizedIsProviderError() async {
        let client = ProviderChatClient(
            streaming: StubLineStream(
                statusCode: 401,
                lines: [#"{"error":{"message":"invalid api key"}}"#]
            )
        )

        let result = await collect(client)

        guard case let .failure(error as ProviderError) = result else {
            return XCTFail("expected ProviderError, got \(result)")
        }
        guard case .http(401, _) = error else {
            return XCTFail("expected http(401), got \(error)")
        }
        XCTAssertTrue(error.message.contains("API Key"))
        XCTAssertFalse(error.message.contains("invalid api key") && error.message.contains("sk-"))
    }

    func testRateLimitIsProviderError() async {
        let client = ProviderChatClient(streaming: StubLineStream(statusCode: 429))

        let result = await collect(client)

        guard case let .failure(error as ProviderError) = result else {
            return XCTFail("expected ProviderError, got \(result)")
        }
        guard case .http(429, _) = error else {
            return XCTFail("expected http(429), got \(error)")
        }
        XCTAssertTrue(error.message.contains("限流"))
        XCTAssertEqual(error.failureCode, "provider_rate_limited")
        XCTAssertTrue(error.retryable)
    }

    func testTransportFailureIsReportedAsNetworkError() async {
        let client = ProviderChatClient(
            streaming: StubLineStream(error: URLError(.cannotConnectToHost))
        )

        let result = await collect(client)

        guard case let .failure(error as ProviderError) = result else {
            return XCTFail("expected ProviderError, got \(result)")
        }
        guard case .transport = error else {
            return XCTFail("expected .transport, got \(error)")
        }
        XCTAssertTrue(error.message.contains("网络"))
        XCTAssertEqual(error.failureCode, "provider_network")
        XCTAssertTrue(error.retryable)
    }

    func testTimeoutHasItsOwnMessage() async {
        let client = ProviderChatClient(
            streaming: StubLineStream(error: URLError(.timedOut))
        )

        let result = await collect(client)

        guard case let .failure(error as ProviderError) = result else {
            return XCTFail("expected ProviderError, got \(result)")
        }
        XCTAssertEqual(error, .timeout)
        XCTAssertTrue(error.message.contains("超时"))
        XCTAssertEqual(error.failureCode, "provider_timeout")
        XCTAssertTrue(error.retryable)
    }

    func testProviderErrorMessagesAreActionable() {
        XCTAssertTrue(ProviderError.http(status: 402, detail: "").message.contains("余额"))
        XCTAssertTrue(ProviderError.http(status: 404, detail: "").message.contains("BaseURL"))
        XCTAssertTrue(ProviderError.emptyReply.message.contains("空"))
        XCTAssertTrue(ProviderError.http(status: 500, detail: "boom").message.contains("boom"))
    }

}

final class MessageComposerTests: XCTestCase {
    private let profile = AgentProfile(
        id: UUID(),
        key: "skeptic",
        name: "质疑派",
        tagline: "先找风险",
        expertise: "风险识别",
        goal: "指出风险",
        defaultStance: "倾向怀疑",
        style: "追问",
        bannedBehaviors: [],
        maxReplyChars: 30
    )

    private func participant(key: String) -> Participant {
        Participant(
            id: UUID(),
            position: 0,
            state: .waiting,
            agent: AgentProfile(
                id: profile.id,
                key: key,
                name: profile.name,
                tagline: profile.tagline,
                expertise: profile.expertise,
                goal: profile.goal,
                defaultStance: profile.defaultStance,
                style: profile.style,
                bannedBehaviors: profile.bannedBehaviors,
                maxReplyChars: profile.maxReplyChars
            )
        )
    }

    private func turn(for participant: Participant) -> ScheduledTurn {
        ScheduledTurn(
            turnId: Fixtures.turnID,
            round: 1,
            roundtableAgentId: participant.id,
            position: participant.position,
            agentKey: participant.agent.key,
            agentName: participant.agent.name
        )
    }

    func testMapsPresetRolesToMessageTypes() {
        XCTAssertEqual(MessageComposer.mapping(for: "advocate").0, .proposal)
        XCTAssertNil(MessageComposer.mapping(for: "advocate").1)
        XCTAssertEqual(MessageComposer.mapping(for: "skeptic").0, .challenge)
        XCTAssertEqual(MessageComposer.mapping(for: "skeptic").1, .challenge)
        XCTAssertEqual(MessageComposer.mapping(for: "experience").0, .supplement)
        XCTAssertEqual(MessageComposer.mapping(for: "experience").1, .supplement)
    }

    func testRecognizesAnExplicitPassWithoutCreatingAnOpinion() {
        XCTAssertTrue(MessageComposer.isPass(" PASS \n"))
        XCTAssertFalse(MessageComposer.isPass("PASS 之后仍然有一个新观点。"))
    }

    func testClaimIsFirstSentenceAndBodyIsTruncated() {
        let participant = participant(key: "skeptic")
        let submission = MessageComposer.compose(
            participant: participant,
            text: "这个方案的风险在于指标自选。后面还有很多解释，但主张只需要第一句。",
            turn: turn(for: participant)
        )

        XCTAssertEqual(submission.claim, "这个方案的风险在于指标自选")
        XCTAssertLessThanOrEqual(submission.body.count, 30)
        XCTAssertEqual(submission.messageType, .challenge)
        XCTAssertEqual(submission.stance, .challenge)
        XCTAssertEqual(submission.confidence, 0.6)
        XCTAssertTrue(submission.references.isEmpty)
    }

    func testClaimIsCappedAt80Characters() {
        let participant = participant(key: "advocate")
        let submission = MessageComposer.compose(
            participant: participant,
            text: String(repeating: "长", count: 200),
            turn: turn(for: participant)
        )

        XCTAssertEqual(submission.claim.count, 80)
    }

    func testSubmissionEncodesWithoutSecrets() throws {
        let participant = participant(key: "advocate")
        let submission = MessageComposer.compose(
            participant: participant,
            text: "先做一个两周实验。",
            turn: turn(for: participant)
        )

        let data = try JSONEncoder.roundtable.encode(submission)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["message_type"] as? String, "proposal")
        XCTAssertEqual(json["claim"] as? String, "先做一个两周实验")
        XCTAssertEqual(json["confidence"] as? Double, 0.6)
        XCTAssertNotNil(json["roundtable_agent_id"])
        XCTAssertEqual(json["turn_id"] as? String, Fixtures.turnID.uuidString)
        for key in json.keys {
            XCTAssertFalse(key.lowercased().contains("key"), "unexpected secret field: \(key)")
        }
    }
}

final class AgentPromptTests: XCTestCase {
    private let topic = "该不该把验证周期压缩到两周？"
    private let agent = AgentProfile(
        id: UUID(),
        key: "advocate",
        name: "方案派",
        tagline: "先给出可执行方案",
        expertise: "方案设计",
        goal: "提出下一步行动",
        defaultStance: "倾向推进",
        style: "直接",
        bannedBehaviors: ["空泛表态"],
        maxReplyChars: 180
    )

    func testSystemPromptCarriesRoleAndLimits() {
        let prompt = AgentPrompt.systemPrompt(topic: topic, agent: agent)

        XCTAssertTrue(prompt.contains("方案派"))
        XCTAssertTrue(prompt.contains("提出下一步行动"))
        XCTAssertTrue(prompt.contains("180"))
        XCTAssertTrue(prompt.contains(topic))
        XCTAssertTrue(prompt.contains("空泛表态"))
        XCTAssertTrue(prompt.contains("只输出 PASS"))
    }

    func testUserPromptIncludesTranscript() {
        let message = Message(
            id: UUID(),
            author: MessageAuthor(roundtableAgentId: UUID(), agentKey: "skeptic", name: "质疑派"),
            messageType: .challenge,
            claim: "指标可能自选",
            body: "指标由我们自己挑选，很容易得到想要的结论。",
            stance: .challenge,
            references: [],
            confidence: 0.6,
            createdAt: Date()
        )

        let prompt = AgentPrompt.userPrompt(topic: topic, transcript: [message])

        XCTAssertTrue(prompt.contains("质疑派："))
        XCTAssertTrue(prompt.contains("指标由我们自己挑选"))
    }

    func testEmptyTranscriptAsksForFirstOpinion() {
        let prompt = AgentPrompt.userPrompt(topic: topic, transcript: [])

        XCTAssertTrue(prompt.contains("还没有人发言"))
    }

    func testSecondRoundPromptRequestsStructuredReviewWithReferenceCandidates() {
        let participant = Participant(
            id: UUID(),
            position: 0,
            state: .waiting,
            agent: agent
        )
        let message = Message(
            id: UUID(uuidString: "6F0E0000-0000-4000-8000-000000000004")!,
            roundNumber: 1,
            author: MessageAuthor(
                roundtableAgentId: UUID(uuidString: "E00E0000-0000-4000-8000-000000000005")!,
                agentKey: "skeptic",
                name: "质疑派"
            ),
            messageType: .challenge,
            claim: "指标可能被自选。",
            body: "验证指标需要预先写清，避免事后挑选。",
            stance: .challenge,
            references: [],
            confidence: 0.7,
            createdAt: Date()
        )

        let system = AgentPrompt.systemPrompt(
            topic: topic,
            agent: agent,
            roundNumber: 2
        )
        let user = AgentPrompt.userPrompt(
            topic: topic,
            transcript: [message],
            roundNumber: 2,
            participant: participant
        )

        XCTAssertTrue(system.contains("JSON"))
        XCTAssertTrue(system.contains("reference_message_id"))
        XCTAssertTrue(system.contains("challenge_target_agent_id"))
        XCTAssertTrue(user.contains("6F0E0000"))
        XCTAssertTrue(user.contains("指标可能被自选"))
    }

    func testSecondRoundPromptWithoutCandidatesRequestsPass() {
        let participant = Participant(
            id: UUID(),
            position: 0,
            state: .waiting,
            agent: agent
        )

        let prompt = AgentPrompt.userPrompt(
            topic: topic,
            transcript: [],
            roundNumber: 2,
            participant: participant
        )

        XCTAssertTrue(prompt.contains("没有可引用的有效观点"))
        XCTAssertTrue(prompt.contains("PASS"))
    }
}
