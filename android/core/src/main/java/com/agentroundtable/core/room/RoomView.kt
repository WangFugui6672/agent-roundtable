package com.agentroundtable.core.room

import com.agentroundtable.core.model.AgentProfile

/** 圆桌参与者。 */
data class ParticipantView(
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

/** 实时连接状态。 */
enum class ConnectionState { Connecting, Connected, Reconnecting, Closed }

/** 讨论流中的一条内容。 */
sealed interface RoomEntry {
    val key: String

    /** 一条已完成的发言。[referenced] 是它引用的那条观点。 */
    data class MessageEntry(
        val message: Message,
        val referenced: Message?,
    ) : RoomEntry {
        override val key: String get() = message.id
    }

    /** 非发言的状态变化，例如开始思考、选择沉默、失败、轮次切换。 */
    data class Notice(
        val id: String,
        val kind: NoticeKind,
        val agentName: String? = null,
        val round: Int = 0,
        val detail: String? = null,
        val retryable: Boolean = false,
        /** 失败时已经生成的部分内容，与完整发言区分展示。 */
        val partial: String? = null,
    ) : RoomEntry {
        override val key: String get() = "notice:$id"
    }
}

enum class NoticeKind {
    RoundStarted,
    RoundCompleted,
    Thinking,
    Typing,
    Passed,
    Failed,
    Paused,
    PausePending,
    Resumed,
    Ended,
    BudgetExhausted,
    SummaryStarted,
}

/** 圆桌界面所需的完整状态。 */
data class RoomView(
    val roundtableId: String = "",
    val topic: String = "",
    val status: String = "",
    val currentRound: Int = 0,
    val maxRounds: Int = 0,
    val participants: List<ParticipantView> = emptyList(),
    val entries: List<RoomEntry> = emptyList(),
    val lastSequence: Int = 0,
    val cursorExpired: Boolean = false,
    /** 未配置 Provider 的圆桌由客户端驱动 Mock 脚本。 */
    val isMock: Boolean = false,
    /** 是否已经收到过 `room.joined` 快照；缓存恢复的视图为 false。 */
    val hasSnapshot: Boolean = false,
    val diagnostic: String? = null,
)

/**
 * 参与者快照转成界面模型。
 *
 * [participantId] 必须是 RoundtableAgent 的 id（Turn 与引用都用它），
 * 不是 AgentProfile 的 id。
 */
internal fun AgentProfile.toParticipant(
    participantId: String,
    position: Int,
    state: String,
) = ParticipantView(
    id = participantId,
    position = position,
    name = name,
    key = key,
    state = state,
    tagline = tagline,
    expertise = expertise,
    goal = goal,
    defaultStance = defaultStance,
    style = style,
    bannedBehaviors = bannedBehaviors,
    maxReplyChars = maxReplyChars,
)
