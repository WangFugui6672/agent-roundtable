package com.agentroundtable.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 匿名会话。UUID 本身即能力凭据，不额外需要密码。 */
@Serializable
data class GuestSession(
    val id: String,
    @SerialName("created_at") val createdAt: String,
)

/** 可复用的 Agent 基础定义。 */
@Serializable
data class AgentProfile(
    val id: String,
    val key: String,
    val name: String,
    val tagline: String,
    val expertise: String,
    val goal: String,
    @SerialName("default_stance") val defaultStance: String,
    val style: String,
    @SerialName("banned_behaviors") val bannedBehaviors: List<String> = emptyList(),
    @SerialName("max_reply_chars") val maxReplyChars: Int = 180,
)

/** 创建圆桌时提交的非秘密 Provider 元数据。 */
@Serializable
data class ProviderMetadata(
    val kind: String,
    @SerialName("base_url") val baseUrl: String,
    val model: String,
)

/** 圆桌在列表与快照中共有的字段子集。 */
@Serializable
data class Roundtable(
    val id: String,
    val topic: String,
    val status: String,
    val mode: String = "decision",
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("max_rounds") val maxRounds: Int = 2,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
)

/** 首页列表中的一张圆桌卡片。 */
data class RoundtableCard(
    val id: String,
    val topic: String,
    val status: RoundtableStatus,
)

/** 圆桌状态。未知值归入 [Unknown]，不阻塞渲染。 */
enum class RoundtableStatus(val wireValue: String) {
    Draft("draft"),
    Ready("ready"),
    Running("running"),
    Paused("paused"),
    Summarizing("summarizing"),
    Completed("completed"),
    Failed("failed"),
    Archived("archived"),
    Unknown("");

    companion object {
        fun fromWire(value: String): RoundtableStatus =
            entries.firstOrNull { it.wireValue == value } ?: Unknown
    }
}
