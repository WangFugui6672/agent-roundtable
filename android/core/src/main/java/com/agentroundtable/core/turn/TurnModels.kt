package com.agentroundtable.core.turn

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 服务端签发给某位参与者的一次发言任务。 */
@Serializable
data class ScheduledTurn(
    @SerialName("turn_id") val turnId: String,
    val round: Int = 0,
    @SerialName("roundtable_agent_id") val roundtableAgentId: String,
    val position: Int = 0,
    @SerialName("agent_key") val agentKey: String = "",
    @SerialName("agent_name") val agentName: String = "",
)

/** `/turns/next` 的响应。[turn] 为 null 表示当前没有可发言的参与者。 */
@Serializable
data class NextTurnResponse(
    val round: Int = 0,
    val turn: ScheduledTurn? = null,
)

@Serializable
data class SubmitMessageRequest(
    @SerialName("turn_id") val turnId: String,
    @SerialName("roundtable_agent_id") val roundtableAgentId: String,
    @SerialName("message_type") val messageType: String,
    val claim: String,
    val body: String,
    val stance: String? = null,
    val references: List<String> = emptyList(),
    @SerialName("challenge_target_agent_id") val challengeTargetAgentId: String? = null,
    val confidence: Double = 0.6,
)

@Serializable
data class PassTurnRequest(
    @SerialName("turn_id") val turnId: String,
    @SerialName("roundtable_agent_id") val roundtableAgentId: String,
)

@Serializable
data class FailTurnRequest(
    @SerialName("turn_id") val turnId: String,
    @SerialName("roundtable_agent_id") val roundtableAgentId: String,
    @SerialName("failure_code") val failureCode: String,
    val message: String,
    val retryable: Boolean,
    val partial: String? = null,
)
