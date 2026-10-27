import Foundation

/// Turns one agent profile plus the roundtable transcript into a chat prompt.
///
/// First-round replies remain plain prose and are assembled by
/// ``MessageComposer``. Second-round replies must be structured JSON and are
/// validated by ``StructuredReplyParser``.
public enum AgentPrompt {
    public static func messages(
        topic: String,
        participant: Participant,
        transcript: [Message],
        roundNumber: Int = 1
    ) -> [ChatMessage] {
        [
            .system(
                systemPrompt(
                    topic: topic,
                    agent: participant.agent,
                    roundNumber: roundNumber
                )
            ),
            .user(
                userPrompt(
                    topic: topic,
                    transcript: transcript,
                    roundNumber: roundNumber,
                    participant: participant
                )
            )
        ]
    }

    static func systemPrompt(
        topic: String,
        agent: AgentProfile,
        roundNumber: Int = 1
    ) -> String {
        let role = """
        你是圆桌讨论中的「\(agent.name)」，\(agent.tagline)。
        你始终是 AI，不得声称自己是真人、公众人物，也不得冒充任何真实个人。
        专长：\(agent.expertise)
        当前目标：\(agent.goal)
        默认立场：\(agent.defaultStance)
        表达风格：\(agent.style)
        禁止行为：\(agent.bannedBehaviors.joined(separator: "、"))
        讨论议题：\(topic)
        """
        if roundNumber >= 2 {
            return """
            \(role)

            现在是第二轮引用式互评。请只返回一个 JSON 对象，不要输出 Markdown 或解释。
            JSON 必须包含：
            - message_type：support、challenge、supplement 或 question。
            - claim：一句话主张，不超过 \(MessageComposer.Limits.claim) 字。
            - body：中文正文，不超过 \(agent.maxReplyChars) 字。
            - stance：必须与 message_type 相同。
            - reference_message_id 或 reference_index：引用候选观点中的一条。
            - challenge_target_agent_id：仅 challenge 时必填，且必须是被引用观点的作者。
            - confidence：0 到 1 之间的数字。
            不得引用自己、用户消息、pass、summary 或候选列表之外的观点。
            如果没有可引用的有效观点，只输出 PASS。
            示例：
            {"message_type":"challenge","claim":"成本被低估",
            "body":"我质疑这个判断，因为注意力也是成本。","stance":"challenge",
            "reference_message_id":"UUID","challenge_target_agent_id":"UUID","confidence":0.7}
            """
        }
        return """
        \(role)

        请直接输出你的发言正文，要求：
        - 用中文，控制在 \(agent.maxReplyChars) 字以内。
        - 只说自己的判断和理由，不要复述议题，不要写“作为 AI”。
        - 不要输出 Markdown 标题、列表标记或 JSON。
        - 不要编造他人没有说过的观点。
        - 如果没有独立、有效的新观点，只输出 PASS，不要解释。
        """
    }

    static func userPrompt(
        topic: String,
        transcript: [Message],
        roundNumber: Int = 1,
        participant: Participant? = nil
    ) -> String {
        let history = transcript
            .map { "\($0.author.name)：\($0.body)" }
            .joined(separator: "\n")
        if roundNumber >= 2, let participant {
            let candidates = StructuredReplyParser.referenceCandidates(
                participant: participant,
                turn: ScheduledTurn(
                    turnId: UUID(),
                    round: roundNumber,
                    roundtableAgentId: participant.id,
                    position: participant.position,
                    agentKey: participant.agent.key,
                    agentName: participant.agent.name
                ),
                transcript: transcript
            )
            if candidates.isEmpty {
                return """
                议题：\(topic)

                目前没有可引用的有效观点。请严格遵守 system 要求，只输出 PASS。
                """
            }
            let eligible = candidates.enumerated().map { index, message in
                """
                [\(index)] id=\(message.id.uuidString)
                作者：\(message.author.name)
                主张：\(message.claim ?? "")
                正文：\(message.body)
                """
            }.joined(separator: "\n")
            return """
            议题：\(topic)

            已有发言：
            \(history)

            可引用的有效观点（只能选择其中一条）：
            \(eligible)

            请按 system 指定的 JSON 结构完成互评。
            """
        }
        guard !transcript.isEmpty else {
            return "议题：\(topic)\n\n目前还没有人发言，请你先给出观点。"
        }
        return """
        议题：\(topic)

        已有发言：
        \(history)

        请基于以上讨论给出你的观点。如果与某条观点相关，请在正文中点明对方的名字。
        """
    }
}
