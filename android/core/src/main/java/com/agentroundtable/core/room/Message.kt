package com.agentroundtable.core.room

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 发言的作者。用户消息与 Agent 消息在此显式区分。 */
@Serializable
data class MessageAuthor(
    val type: String,
    @SerialName("roundtable_agent_id") val roundtableAgentId: String? = null,
    @SerialName("agent_key") val agentKey: String? = null,
    val name: String,
) {
    val isUser: Boolean get() = type == "user"
}

/** 一条可持久化内容。 */
@Serializable
data class Message(
    val id: String,
    @SerialName("turn_id") val turnId: String? = null,
    @SerialName("round_number") val roundNumber: Int = 0,
    val author: MessageAuthor,
    @SerialName("message_type") val messageType: String = "proposal",
    val claim: String? = null,
    val body: String = "",
    val stance: String? = null,
    val references: List<String> = emptyList(),
    @SerialName("challenge_target_agent_id") val challengeTargetAgentId: String? = null,
    val confidence: Double? = null,
    @SerialName("is_key_point") val isKeyPoint: Boolean = false,
    @SerialName("supersedes_message_id") val supersedesMessageId: String? = null,
    @SerialName("superseded_by_message_id") val supersededByMessageId: String? = null,
    @SerialName("created_at") val createdAt: String = "",
)

/** 四种合法立场。 */
enum class Stance(val wireValue: String) {
    Support("support"),
    Challenge("challenge"),
    Supplement("supplement"),
    Question("question");

    companion object {
        fun fromWire(value: String?): Stance? =
            entries.firstOrNull { it.wireValue == value }
    }
}
