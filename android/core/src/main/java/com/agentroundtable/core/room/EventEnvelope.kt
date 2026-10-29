package com.agentroundtable.core.room

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** WebSocket 事件的统一信封。 */
@Serializable
data class EventEnvelope(
    @kotlinx.serialization.SerialName("event_id") val eventId: String,
    @kotlinx.serialization.SerialName("room_id") val roomId: String,
    val sequence: Int,
    @kotlinx.serialization.SerialName("created_at") val createdAt: String = "",
    @kotlinx.serialization.SerialName("event_type") val eventType: String,
    val payload: JsonObject,
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun decode(text: String): EventEnvelope? = try {
            json.decodeFromString<EventEnvelope>(text)
        } catch (error: Exception) {
            null
        }

        /** 解析 `room.joined` 的负载；失败时返回 null，由调用方决定是否忽略。 */
        fun decodeJoined(text: String): RoomJoinedPayload? = try {
            val envelope = json.decodeFromString<EventEnvelope>(text)
            json.decodeFromString<RoomJoinedPayload>(envelope.payload.toString())
        } catch (error: Exception) {
            null
        }
    }
}

/** 服务端已实现的事件类型。未知类型必须被忽略，但游标仍然前进。 */
object EventTypes {
    const val ROOM_JOINED = "room.joined"
    const val ROUND_STARTED = "round.started"
    const val ROUND_COMPLETED = "round.completed"
    const val AGENT_THINKING = "agent.thinking"
    const val AGENT_TYPING = "agent.typing"
    const val AGENT_PASSED = "agent.passed"
    const val AGENT_FAILED = "agent.failed"
    const val MESSAGE_COMPLETED = "message.completed"
    const val BUDGET_EXHAUSTED = "budget.exhausted"
    const val ROOM_PAUSE_PENDING = "room.pause_pending"
    const val ROOM_PAUSED = "room.paused"
    const val ROOM_RESUMED = "room.resumed"
    const val ROOM_ENDED = "room.ended"
    const val SUMMARY_STARTED = "summary.started"
    const val SUMMARY_COMPLETED = "summary.completed"
}
