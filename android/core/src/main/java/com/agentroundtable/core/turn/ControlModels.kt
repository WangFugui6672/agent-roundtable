package com.agentroundtable.core.turn

import com.agentroundtable.core.room.EventEnvelope
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 控制命令与用户消息统一返回：最新快照 + 本次产生的事件。 */
@Serializable
data class ControlResponse(
    @SerialName("roundtable") val roundtable: ControlSnapshot? = null,
    val events: List<EventEnvelope> = emptyList(),
)

/** 命令响应中的圆桌快照，只取客户端需要校正的字段。 */
@Serializable
data class ControlSnapshot(
    val id: String = "",
    val status: String = "",
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("last_sequence") val lastSequence: Int = 0,
    @SerialName("pause_pending") val pausePending: Boolean = false,
)

/** 发送用户消息的请求体；点名的唯一依据是 [mentionedAgentIds]。 */
@Serializable
data class UserMessageRequest(
    val body: String,
    @SerialName("mentioned_agent_ids") val mentionedAgentIds: List<String> = emptyList(),
)
