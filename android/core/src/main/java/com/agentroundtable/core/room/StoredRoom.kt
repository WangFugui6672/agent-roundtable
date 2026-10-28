package com.agentroundtable.core.room

import com.agentroundtable.core.model.RoundSummary
import kotlinx.serialization.Serializable

/** 参与者在本机的快照。 */
@Serializable
data class StoredParticipant(
    val id: String,
    val position: Int,
    val name: String,
    val key: String,
    val state: String,
    val tagline: String = "",
    val expertise: String = "",
    val goal: String = "",
    val defaultStance: String = "",
    val style: String = "",
    val bannedBehaviors: List<String> = emptyList(),
    val maxReplyChars: Int = 180,
)

/**
 * 一台设备上缓存的圆桌现场。
 *
 * 只保存可以重建界面的数据：状态提示这类临时信息在恢复时丢弃，
 * 因为它们随时可以由重连后的事件重新产生。
 */
@Serializable
data class StoredRoom(
    val roundtableId: String,
    val topic: String,
    val status: String,
    val currentRound: Int,
    val maxRounds: Int,
    val participants: List<StoredParticipant>,
    val messages: List<Message>,
    /** 已保存的结论；旧缓存没有该字段时为 null。 */
    val summary: RoundSummary? = null,
    /** 已处理到的事件序号，重连时作为 `cursor` 发送。 */
    val lastSequence: Int,
    val savedAt: Long,
)

/** 圆桌缓存接缝。删除必须先写墓碑，避免清理失败导致已删除内容复活。 */
interface RoomCache {
    suspend fun load(roundtableId: String): StoredRoom?

    suspend fun save(room: StoredRoom)

    suspend fun list(): List<StoredRoom>

    /** 先写删除墓碑，再移除缓存。 */
    suspend fun delete(roundtableId: String)

    suspend fun isDeleted(roundtableId: String): Boolean
}
