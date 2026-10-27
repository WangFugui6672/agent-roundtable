import Foundation

public enum ContentPolicyDecision: String, Codable, Sendable {
    case allow
    case block
    case flag
}

public enum ContentCategory: String, Codable, CaseIterable, Sendable {
    case unlawful
    case dangerous
    case hate
    case sexual
    case harassment
    case impersonation
    case privacy
}

public struct ContentPolicyResult: Equatable, Sendable {
    public let decision: ContentPolicyDecision
    public let categories: [ContentCategory]
    public let ruleIDs: [String]
    public let message: String?

    public init(
        decision: ContentPolicyDecision,
        categories: [ContentCategory] = [],
        ruleIDs: [String] = [],
        message: String? = nil
    ) {
        self.decision = decision
        self.categories = categories
        self.ruleIDs = ruleIDs
        self.message = message
    }
}

/// Deterministic, on-device rules for clearly harmful content.
///
/// This is deliberately a narrow first-pass filter, not a moderation verdict.
/// High-precision operational patterns block; lower-confidence context is shown
/// with a local flag so users understand that no review has taken place.
public struct ContentPolicy: Sendable {
    public static let standard = ContentPolicy(rules: ContentRule.standard)

    private let rules: [ContentRule]

    public init(rules: [ContentRule]) {
        self.rules = rules
    }

    public func evaluate(_ text: String) -> ContentPolicyResult {
        let normalized = ContentPolicy.normalize(text)
        guard !normalized.isEmpty else {
            return ContentPolicyResult(decision: .allow)
        }

        let matches = rules.filter { rule in
            rule.patterns.contains { pattern in
                normalized.range(
                    of: pattern,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
        }
        guard !matches.isEmpty else {
            return ContentPolicyResult(decision: .allow)
        }

        let decision: ContentPolicyDecision = matches.contains { $0.decision == .block }
            ? .block
            : .flag
        let categories = ContentCategory.allCases.filter { category in
            matches.contains { $0.category == category }
        }
        let ruleIDs = Array(Set(matches.map(\.id))).sorted()
        return ContentPolicyResult(
            decision: decision,
            categories: categories,
            ruleIDs: ruleIDs,
            message: decision == .block
                ? "本地安全规则已阻止这段内容，内容没有发送给服务端或模型服务商。"
                : "本地规则标记了这段内容；它未经模型或人工审核，不代表已判定违规。"
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ContentRule: Equatable, Sendable {
    public let id: String
    public let category: ContentCategory
    public let decision: ContentPolicyDecision
    public let patterns: [String]

    public init(
        id: String,
        category: ContentCategory,
        decision: ContentPolicyDecision,
        patterns: [String]
    ) {
        self.id = id
        self.category = category
        self.decision = decision
        self.patterns = patterns
    }

    static let standard: [ContentRule] = [
        ContentRule(
            id: "danger.weapon-instructions",
            category: .dangerous,
            decision: .block,
            patterns: [
                #"(?:教我|告诉我|帮我|提供|给出|写出).{0,16}(?:制作|合成|组装|制造|引爆|投放).{0,16}(?:炸弹|爆炸物|毒气|生化武器|燃烧瓶)"#,
                #"(?:炸弹|爆炸物|毒气|生化武器|燃烧瓶).{0,8}(?:制作步骤|制作教程|制作方法|组装方法|引爆步骤)"#
            ]
        ),
        ContentRule(
            id: "danger.self-harm-instructions",
            category: .dangerous,
            decision: .block,
            patterns: [
                #"(?:如何|怎么)(?:自杀|割腕|上吊|烧炭|服毒)(?:方法|步骤|教程|最快|不痛苦)?"#,
                #"(?:自杀|割腕|上吊|烧炭|服毒).{0,12}(?:方法|步骤|教程)"#
            ]
        ),
        ContentRule(
            id: "unlawful.violent-crime",
            category: .unlawful,
            decision: .block,
            patterns: [
                #"(?:绑架|杀害|投毒|抢劫)(?:别人|某人|一个人|他|她)?(?:的)?(?:步骤|方法|教程|怎么做)"#,
                #"(?:教我|告诉我).{0,4}(?:绑架|杀害|投毒|抢劫)"#
            ]
        ),
        ContentRule(
            id: "unlawful.minor-sexual-abuse",
            category: .unlawful,
            decision: .block,
            patterns: [
                #"(?:儿童|未成年|幼女|幼童).{0,12}(?:裸照|色情|性交|性行为|淫秽)"#,
                #"(?:裸照|色情|性交|性行为|淫秽).{0,12}(?:儿童|未成年|幼女|幼童)"#
            ]
        ),
        ContentRule(
            id: "hate.incitement",
            category: .hate,
            decision: .block,
            patterns: [
                #"(?:杀光|消灭|清洗|灭绝|驱逐).{0,12}(?:黑人|白人|犹太人|穆斯林|中国人|日本人|某族|某民族|少数民族)"#,
                #"(?:劣等民族|低等种族|不配活着)"#
            ]
        ),
        ContentRule(
            id: "impersonation.public-figure",
            category: .impersonation,
            decision: .block,
            patterns: [
                #"(?:冒充|扮演|假扮|模拟|以).{0,10}(?:习近平|特朗普|拜登|马斯克|普京|泽连斯基|总统|首相|国家主席|明星|名人).{0,10}(?:身份|口吻|名义)"#,
                #"我是(?:习近平|特朗普|拜登|马斯克|普京|泽连斯基)"#
            ]
        ),
        ContentRule(
            id: "harassment.insult",
            category: .harassment,
            decision: .flag,
            patterns: [#"(?:废物|垃圾|去死|滚开|蠢货|白痴|丑八怪)"#]
        ),
        ContentRule(
            id: "violent.threat",
            category: .dangerous,
            decision: .flag,
            patterns: [#"(?:杀死|杀掉|殴打|伤害|报复).{0,10}(?:你|他|她|他们|她们)"#]
        ),
        ContentRule(
            id: "sexual.adult-content",
            category: .sexual,
            decision: .flag,
            patterns: [#"(?:色情|裸照|性交|性行为|约炮)"#]
        ),
        ContentRule(
            id: "self-harm.expression",
            category: .dangerous,
            decision: .flag,
            patterns: [#"(?:我想自杀|不想活了|活着没意思|想结束生命)"#]
        ),
        ContentRule(
            id: "privacy.personal-identifier",
            category: .privacy,
            decision: .flag,
            patterns: [
                #"(?<!\d)1[3-9]\d{9}(?!\d)"#,
                #"(?<!\d)\d{17}[\dXx](?!\d)"#
            ]
        )
    ]
}
