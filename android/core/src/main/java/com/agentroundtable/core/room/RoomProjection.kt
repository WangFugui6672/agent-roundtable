package com.agentroundtable.core.room

import com.agentroundtable.core.model.RoundSummary
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * 把事件流投影成界面状态。
 *
 * 这里是协议语义的唯一实现：游标推进、事件去重、快照重置都在这个类里完成，
 * 因此可以完全脱离 Android 与网络在 JVM 上测试。
 */
class RoomProjection(
    private val maxSeenEventIds: Int = 500,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val seenEventIds = LinkedHashSet<String>()
    private val messagesById = LinkedHashMap<String, Message>()
    private val entries = mutableListOf<RoomEntry>()

    private var view = RoomView()

    fun snapshot(): RoomView = view

    /** 从本机缓存恢复，先给出可离线阅读的界面，再等待重连补发。 */
    fun restore(stored: StoredRoom) {
        seenEventIds.clear()
        messagesById.clear()
        entries.clear()
        stored.messages.forEach { message ->
            messagesById[message.id] = message
            entries += messageEntry(message)
        }
        view = stored.toRoomView()
    }

    /**
     * 应用 `room.joined`。
     *
     * @param localCursor 本机已持久化的游标；为 null 表示没有本地记录。
     * 快照的 `sequence` 固定为 0，永远不推进游标；只有当补发窗口过期或本地无记录时，
     * 才用快照的 `last_sequence` 建立新游标。
     */
    fun present(payload: RoomJoinedPayload, localCursor: Int?): RoomView {
        val replay = payload.replay
        val cursorExpired = replay?.cursorExpired == true
        val cursor = when {
            localCursor == null -> payload.roundtable.lastSequence
            cursorExpired -> payload.roundtable.lastSequence
            else -> localCursor
        }

        messagesById.clear()
        entries.clear()
        payload.messages.forEach { message ->
            messagesById[message.id] = message
            entries += messageEntry(message)
        }

        view = RoomView(
            roundtableId = payload.roundtable.id,
            topic = payload.roundtable.topic,
            status = payload.roundtable.status,
            currentRound = payload.roundtable.currentRound,
            maxRounds = payload.roundtable.maxRounds,
            participants = payload.roundtable.participants.map {
                it.agent.toParticipant(
                    participantId = it.id,
                    position = it.position,
                    state = it.state,
                )
            },
            entries = entries.toList(),
            summary = payload.summary ?: view.summary,
            lastSequence = cursor,
            cursorExpired = cursorExpired,
            isMock = payload.roundtable.provider == null,
            hasSnapshot = true,
        )
        return view
    }

    /**
     * 应用一条实时或补发事件。
     *
     * @return true 表示状态发生了变化。重复事件返回 false，未知事件返回 false 但游标仍前进。
     */
    fun apply(envelope: EventEnvelope): Boolean {
        if (envelope.eventType == EventTypes.ROOM_JOINED) return false
        if (!remember(envelope.eventId)) return false

        // 游标按已持久化事件的最大序号推进，与投影是否产生可见变化无关。
        val advanced = envelope.sequence > view.lastSequence
        if (advanced) {
            view = view.copy(lastSequence = envelope.sequence)
        }

        val changed = when (envelope.eventType) {
            EventTypes.MESSAGE_COMPLETED -> applyMessage(envelope.payload)
            EventTypes.ROUND_STARTED -> applyRoundStarted(envelope.payload)
            EventTypes.ROUND_COMPLETED -> applyRoundCompleted(envelope.payload)
            EventTypes.AGENT_THINKING -> applyThinking(envelope.payload)
            EventTypes.AGENT_TYPING -> applyTyping(envelope.payload)
            EventTypes.AGENT_PASSED -> applyPassed(envelope.payload)
            EventTypes.AGENT_FAILED -> applyFailed(envelope.payload)
            EventTypes.BUDGET_EXHAUSTED -> applyBudget(envelope.payload)
            EventTypes.ROOM_PAUSE_PENDING -> notice(envelope, NoticeKind.PausePending)
            EventTypes.ROOM_PAUSED -> applyRoomStatus(envelope.payload, NoticeKind.Paused, "paused")
            EventTypes.ROOM_RESUMED -> applyRoomStatus(envelope.payload, NoticeKind.Resumed, "running")
            EventTypes.ROOM_ENDED -> applyRoomStatus(envelope.payload, NoticeKind.Ended, "summarizing")
            EventTypes.SUMMARY_STARTED -> applySummaryStarted(envelope.payload)
            EventTypes.SUMMARY_COMPLETED -> applySummaryCompleted(envelope.payload)
            else -> false // 未知事件：忽略，但游标已经前进
        }

        if (changed) {
            view = view.copy(entries = entries.toList())
        }
        return changed || advanced
    }

    /** 记录一个事件 ID，超出上限时淘汰最早的一条。 */
    private fun remember(eventId: String): Boolean {
        if (!seenEventIds.add(eventId)) return false
        while (seenEventIds.size > maxSeenEventIds) {
            seenEventIds.remove(seenEventIds.first())
        }
        return true
    }

    private fun applyMessage(payload: JsonObject): Boolean {
        val message = decode<MessageCompletedPayload>(payload)?.message ?: return false
        if (messagesById.containsKey(message.id)) return false
        messagesById[message.id] = message
        entries += messageEntry(message)
        return true
    }

    /** 引用在到达时就已存在：引用只能指向同一圆桌中更早的观点。 */
    private fun messageEntry(message: Message) = RoomEntry.MessageEntry(
        message = message,
        referenced = message.references.firstOrNull()?.let { messagesById[it] },
    )

    private fun applyRoundStarted(payload: JsonObject): Boolean {
        val data = decode<RoundStartedPayload>(payload) ?: return false
        view = view.copy(
            currentRound = data.round.takeIf { it > 0 } ?: view.currentRound,
            maxRounds = data.maxRounds.takeIf { it > 0 } ?: view.maxRounds,
            status = "running",
        )
        addNotice(NoticeKind.RoundStarted, round = data.round)
        return true
    }

    private fun applyRoundCompleted(payload: JsonObject): Boolean {
        val data = decode<RoundCompletedPayload>(payload) ?: return false
        addNotice(NoticeKind.RoundCompleted, round = data.round)
        return true
    }

    private fun applyThinking(payload: JsonObject): Boolean {
        val data = decode<AgentThinkPayload>(payload) ?: return false
        addNotice(NoticeKind.Thinking, agentName = data.agentName, round = data.round)
        return true
    }

    private fun applyTyping(payload: JsonObject): Boolean {
        val data = decode<AgentTypingPayload>(payload) ?: return false
        addNotice(NoticeKind.Typing, agentName = agentName(data.agentId))
        return true
    }

    private fun agentName(agentId: String): String? =
        view.participants.firstOrNull { it.id == agentId }?.name

    private fun applyPassed(payload: JsonObject): Boolean {
        val data = decode<AgentPassedPayload>(payload) ?: return false
        addNotice(NoticeKind.Passed, agentName = data.agentName, round = data.round)
        return true
    }

    private fun applyFailed(payload: JsonObject): Boolean {
        val data = decode<AgentFailedPayload>(payload) ?: return false
        addNotice(
            NoticeKind.Failed,
            agentName = data.agentName,
            round = data.round,
            detail = data.message.ifBlank { data.failureCode },
            retryable = com.agentroundtable.core.turn.FailureKind.retryable(
                data.failureCode,
                data.retryable,
            ),
            partial = data.partial,
        )
        return true
    }

    private fun applyBudget(payload: JsonObject): Boolean {
        val data = decode<BudgetExhaustedPayload>(payload) ?: return false
        addNotice(NoticeKind.BudgetExhausted, round = data.round, detail = data.detail)
        return true
    }

    private fun applyRoomStatus(payload: JsonObject, kind: NoticeKind, status: String): Boolean {
        decode<RoomStatusPayload>(payload) ?: return false
        view = view.copy(status = status)
        addNotice(kind)
        return true
    }

    private fun applySummaryStarted(payload: JsonObject): Boolean {
        val data = decode<SummaryStartedPayload>(payload) ?: return false
        view = view.copy(status = "summarizing")
        addNotice(NoticeKind.SummaryStarted, round = data.round)
        return true
    }

    private fun applySummaryCompleted(payload: JsonObject): Boolean {
        val data = decode<SummaryCompletedPayload>(payload) ?: return false
        view = view.copy(status = "completed", summary = data.summary)
        return true
    }

    /**
     * 合并一次结论提交响应。
     *
     * 幂等重试可能没有 `summary.completed` 事件，因此这里直接用响应中的结论与快照校正状态。
     */
    fun applySummary(
        summary: RoundSummary,
        status: String? = null,
        currentRound: Int? = null,
    ): Boolean {
        val nextStatus = status?.takeIf { it.isNotBlank() } ?: view.status
        val nextRound = currentRound?.takeIf { it > 0 } ?: view.currentRound
        val changed = view.summary != summary ||
            view.status != nextStatus ||
            view.currentRound != nextRound
        if (changed) {
            view = view.copy(
                status = nextStatus,
                currentRound = nextRound,
                summary = summary,
            )
        }
        return changed
    }

    private fun notice(envelope: EventEnvelope, kind: NoticeKind): Boolean {
        addNotice(kind, id = envelope.eventId)
        return true
    }

    private fun addNotice(
        kind: NoticeKind,
        id: String = "n${entries.size}",
        agentName: String? = null,
        round: Int = 0,
        detail: String? = null,
        retryable: Boolean = false,
        partial: String? = null,
    ) {
        entries += RoomEntry.Notice(
            id = id,
            kind = kind,
            agentName = agentName,
            round = round,
            detail = detail,
            retryable = retryable,
            partial = partial,
        )
    }

    private inline fun <reified T> decode(payload: JsonObject): T? = try {
        json.decodeFromString<T>(payload.toString())
    } catch (error: Exception) {
        null
    }
}
