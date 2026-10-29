package com.agentroundtable.core.room

import com.agentroundtable.core.model.AgentProfile
import com.agentroundtable.core.model.RoundSummary
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** `room.joined` 快照中的参与者。 */
@Serializable
data class ParticipantSnapshot(
    val id: String,
    val position: Int = 0,
    val state: String = "waiting",
    val agent: AgentProfile,
)

/** `room.joined` 快照中的圆桌本体。 */
@Serializable
data class RoomSnapshot(
    val id: String,
    val topic: String,
    val status: String = "",
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("max_rounds") val maxRounds: Int = 0,
    @SerialName("last_sequence") val lastSequence: Int = 0,
    val provider: com.agentroundtable.core.model.ProviderMetadata? = null,
    val participants: List<ParticipantSnapshot> = emptyList(),
)

/** 补发窗口信息。 */
@Serializable
data class ReplayMetadata(
    @SerialName("requested_cursor") val requestedCursor: Int? = null,
    @SerialName("oldest_sequence") val oldestSequence: Int? = null,
    @SerialName("latest_sequence") val latestSequence: Int? = null,
    @SerialName("window_days") val windowDays: Int = 0,
    @SerialName("cursor_expired") val cursorExpired: Boolean = false,
)

/** `room.joined` 的完整负载。 */
@Serializable
data class RoomJoinedPayload(
    val roundtable: RoomSnapshot,
    val messages: List<Message> = emptyList(),
    /** 已完成圆桌的结论；未生成时为 null。 */
    val summary: RoundSummary? = null,
    val replay: ReplayMetadata? = null,
)

@Serializable
internal data class RoundStartedPayload(
    val round: Int = 0,
    @SerialName("max_rounds") val maxRounds: Int = 0,
)

@Serializable
internal data class RoundCompletedPayload(val round: Int = 0)

@Serializable
internal data class AgentThinkPayload(
    val round: Int = 0,
    @SerialName("agent_id") val agentId: String = "",
    @SerialName("agent_name") val agentName: String = "",
)

@Serializable
internal data class AgentTypingPayload(@SerialName("agent_id") val agentId: String = "")

@Serializable
internal data class AgentPassedPayload(
    val round: Int = 0,
    @SerialName("agent_name") val agentName: String = "",
)

@Serializable
internal data class AgentFailedPayload(
    val round: Int = 0,
    @SerialName("agent_name") val agentName: String = "",
    @SerialName("failure_code") val failureCode: String = "",
    val message: String = "",
    val retryable: Boolean = false,
    val partial: String? = null,
)

@Serializable
internal data class MessageCompletedPayload(val message: Message)

@Serializable
internal data class BudgetExhaustedPayload(
    val reason: String = "",
    @SerialName("message") val detail: String = "",
    val round: Int = 0,
)

@Serializable
internal data class RoomStatusPayload(val status: String = "")

@Serializable
internal data class SummaryStartedPayload(val round: Int = 0)

@Serializable
internal data class SummaryCompletedPayload(val summary: RoundSummary)
