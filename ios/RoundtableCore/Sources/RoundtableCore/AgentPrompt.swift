import Foundation

/// Turns one agent profile plus the roundtable transcript into a chat prompt.
///
/// The model writes plain prose; the structured envelope (type, stance, claim,
/// confidence) is assembled by ``MessageComposer`` so a malformed model reply
/// cannot break the protocol.
public enum AgentPrompt {
    public static func messages(
        topic: String,
        participant: Participant,
        transcript: [Message]
    ) -> [ChatMessage] {
        [.system(systemPrompt(topic: topic, agent: participant.agent)),
         .user(userPrompt(topic: topic, transcript: transcript))]
    }

    static func systemPrompt(topic: String, agent: AgentProfile) -> String {
        """
        你是圆桌讨论中的「\(agent.name)」，\(agent.tagline)。
        专长：\(agent.expertise)
        当前目标：\(agent.goal)
        默认立场：\(agent.defaultStance)
        表达风格：\(agent.style)
        禁止行为：\(agent.bannedBehaviors.joined(separator: "、"))
        讨论议题：\(topic)

        请直接输出你的发言正文，要求：
        - 用中文，控制在 \(agent.maxReplyChars) 字以内。
        - 只说自己的判断和理由，不要复述议题，不要写“作为 AI”。
        - 不要输出 Markdown 标题、列表标记或 JSON。
        - 不要编造他人没有说过的观点。
        """
    }

    static func userPrompt(topic: String, transcript: [Message]) -> String {
        guard !transcript.isEmpty else {
            return "议题：\(topic)\n\n目前还没有人发言，请你先给出观点。"
        }
        let history = transcript
            .map { "\($0.author.name)：\($0.body)" }
            .joined(separator: "\n")
        return """
        议题：\(topic)

        已有发言：
        \(history)

        请基于以上讨论给出你的观点。如果与某条观点相关，请在正文中点明对方的名字。
        """
    }
}
