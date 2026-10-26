import Foundation

public struct SummaryDraft: Equatable, Sendable {
    public let degraded: Bool
    public let consensus: [SummaryItem]
    public let dissent: [SummaryItem]
    public let recommendations: [SummaryItem]
    public let unresolved: [SummaryItem]

    public init(
        degraded: Bool,
        consensus: [SummaryItem],
        dissent: [SummaryItem],
        recommendations: [SummaryItem],
        unresolved: [SummaryItem]
    ) {
        self.degraded = degraded
        self.consensus = consensus
        self.dissent = dissent
        self.recommendations = recommendations
        self.unresolved = unresolved
    }

    public func submission(expectedVersion: Int) -> RoundSummarySubmission {
        RoundSummarySubmission(
            expectedVersion: expectedVersion,
            degraded: degraded,
            consensus: consensus,
            dissent: dissent,
            recommendations: recommendations,
            unresolved: unresolved
        )
    }
}

public enum StructuredSummaryError: Error, Equatable, Sendable {
    case invalidJSON
    case emptySummary
    case invalidText
    case invalidReference
    case tooManyItems
    case tooManyReferences

    public var message: String {
        switch self {
        case .invalidJSON:
            return "模型返回的结论不是合法 JSON。"
        case .emptySummary:
            return "结论没有包含任何可引用观点。"
        case .invalidText:
            return "结论项正文为空或超过 400 字。"
        case .invalidReference:
            return "结论项引用了候选讨论之外的来源。"
        case .tooManyItems:
            return "单个结论分组超过 8 项。"
        case .tooManyReferences:
            return "单个结论项必须引用 1 到 3 条观点。"
        }
    }
}

public enum StructuredSummaryParser {
    public static let maxItemsPerSection = 8
    public static let maxReferencesPerItem = 3
    public static let maxTextCharacters = 400

    public static func parse(_ raw: String, transcript: [Message]) throws -> SummaryDraft {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["consensus", "dissent", "recommendations", "unresolved"]),
              object.values.allSatisfy({ value in
                  guard let section = value as? [[String: Any]] else { return false }
                  return section.allSatisfy {
                      Set($0.keys) == Set(["text", "reference_indexes"])
                  }
              }),
              let output = try? JSONDecoder.roundtable.decode(SummaryModelOutput.self, from: data)
        else {
            throw StructuredSummaryError.invalidJSON
        }
        let candidates = eligibleMessages(from: transcript)
        let sections = [
            output.consensus,
            output.dissent,
            output.recommendations,
            output.unresolved
        ]
        guard sections.allSatisfy({ $0.count <= maxItemsPerSection }) else {
            throw StructuredSummaryError.tooManyItems
        }
        guard sections.contains(where: { !$0.isEmpty }) else {
            throw StructuredSummaryError.emptySummary
        }

        func items(_ section: [SummaryModelItem]) throws -> [SummaryItem] {
            try section.map { item in
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= maxTextCharacters else {
                    throw StructuredSummaryError.invalidText
                }
                guard !item.referenceIndexes.isEmpty,
                      item.referenceIndexes.count <= maxReferencesPerItem,
                      Set(item.referenceIndexes).count == item.referenceIndexes.count,
                      item.referenceIndexes.allSatisfy({
                          candidates.indices.contains($0)
                      })
                else {
                    throw StructuredSummaryError.invalidReference
                }
                return SummaryItem(
                    text: text,
                    referenceMessageIds: item.referenceIndexes.map { candidates[$0].id }
                )
            }
        }

        return SummaryDraft(
            degraded: false,
            consensus: try items(output.consensus),
            dissent: try items(output.dissent),
            recommendations: try items(output.recommendations),
            unresolved: try items(output.unresolved)
        )
    }

    public static func eligibleMessages(from transcript: [Message]) -> [Message] {
        transcript.filter { message in
            guard message.author.type == .agent else { return false }
            guard [.proposal, .support, .challenge, .supplement, .question]
                .contains(message.messageType)
            else {
                return false
            }
            return !(message.claim ?? message.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }
}

public enum RuleBasedSummary {
    public static func make(transcript: [Message]) -> SummaryDraft {
        let candidates = StructuredSummaryParser.eligibleMessages(from: transcript)
        func items(for types: Set<MessageType>) -> [SummaryItem] {
            candidates
                .filter { types.contains($0.messageType) }
                .prefix(StructuredSummaryParser.maxItemsPerSection)
                .compactMap { message in
                    let text = (message.claim ?? message.body)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return SummaryItem(
                        text: String(text.prefix(StructuredSummaryParser.maxTextCharacters)),
                        referenceMessageIds: [message.id]
                    )
                }
        }
        return SummaryDraft(
            degraded: true,
            consensus: items(for: [.support]),
            dissent: items(for: [.challenge]),
            recommendations: items(for: [.proposal, .supplement]),
            unresolved: items(for: [.question])
        )
    }
}

public enum SummaryPrompt {
    public static func messages(
        topic: String,
        transcript: [Message],
        followUpContext: FollowUpContext? = nil
    ) -> [ChatMessage] {
        let candidates = StructuredSummaryParser.eligibleMessages(from: transcript)
        let candidateText = candidates.enumerated().map { index, message in
            """
            [\(index)] 作者：\(message.author.name)
            主张：\(message.claim ?? "")
            正文：\(message.body)
            """
        }.joined(separator: "\n\n")
        let priorContext = followUpContext.map { context in
            let items = [
                context.summary.consensus,
                context.summary.dissent,
                context.summary.recommendations,
                context.summary.unresolved
            ]
            .flatMap { $0 }
            .map(\.text)
            .joined(separator: "\n")
            return """

            这是继续追问的新圆桌。上一场议题：\(context.parentTopic)
            上一场结论：
            \(items)
            """
        } ?? ""

        return [
            .system(
                """
                你是圆桌主持人。请只输出一个 JSON 对象，不要 Markdown 或解释。
                输出必须恰好包含 consensus、dissent、recommendations、unresolved 四个数组。
                每个数组最多 8 项；每项必须包含：
                - text：只复述引用观点能够支持的内容，1-400 字。
                - reference_indexes：1-3 个候选观点编号。
                不得引入候选观点之外的事实、数字、人物或建议。
                没有依据时输出空数组。分歧不能包装成共识。
                \(priorContext)
                """
            ),
            .user(
                """
                议题：\(topic)

                可引用观点：
                \(candidateText)
                """
            )
        ]
    }
}

private struct SummaryModelOutput: Decodable {
    let consensus: [SummaryModelItem]
    let dissent: [SummaryModelItem]
    let recommendations: [SummaryModelItem]
    let unresolved: [SummaryModelItem]
}

private struct SummaryModelItem: Decodable {
    let text: String
    let referenceIndexes: [Int]
}
