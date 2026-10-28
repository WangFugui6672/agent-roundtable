package com.agentroundtable.core.room

/** 从本机缓存重建界面状态。 */
fun StoredRoom.toRoomView(): RoomView {
    val byId = messages.associateBy { it.id }
    return RoomView(
        roundtableId = roundtableId,
        topic = topic,
        status = status,
        currentRound = currentRound,
        maxRounds = maxRounds,
        participants = participants.map {
            ParticipantView(it.id, it.position, it.name, it.key, it.state)
        },
        entries = messages.map { message ->
            RoomEntry.MessageEntry(
                message = message,
                referenced = message.references.firstOrNull()?.let { byId[it] },
            )
        },
        lastSequence = lastSequence,
    )
}

/** 把当前界面状态收成可持久化的形状。 */
fun RoomView.toStoredRoom(savedAt: Long): StoredRoom = StoredRoom(
    roundtableId = roundtableId,
    topic = topic,
    status = status,
    currentRound = currentRound,
    maxRounds = maxRounds,
    participants = participants.map {
        StoredParticipant(it.id, it.position, it.name, it.key, it.state)
    },
    messages = entries.filterIsInstance<RoomEntry.MessageEntry>().map { it.message },
    lastSequence = lastSequence,
    savedAt = savedAt,
)
