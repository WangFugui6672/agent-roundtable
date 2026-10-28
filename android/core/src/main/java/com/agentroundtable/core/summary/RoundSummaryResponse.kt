package com.agentroundtable.core.summary

import com.agentroundtable.core.model.RoundSummary
import com.agentroundtable.core.room.EventEnvelope
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** 结论提交响应中的圆桌快照，只保留客户端需要校正的字段。 */
@Serializable
data class RoundSummaryRoundtable(
    val id: String = "",
    val status: String = "",
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("last_sequence") val lastSequence: Int = 0,
)

/** `POST /summary` 的响应。幂等重试时 [events] 为空。 */
@Serializable
data class RoundSummaryResponse(
    val roundtable: RoundSummaryRoundtable = RoundSummaryRoundtable(),
    val summary: RoundSummary,
    val events: List<EventEnvelope> = emptyList(),
)
