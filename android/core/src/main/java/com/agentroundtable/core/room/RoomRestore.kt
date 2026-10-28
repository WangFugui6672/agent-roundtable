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
            ParticipantView(
                id = it.id,
                position = it.position,
                name = it.name,
                key = it.key,
                state = it.state,
                tagline = it.tagline,
                expertise = it.expertise,
                goal = it.goal,
                defaultStance = it.defaultStance,
                style = it.style,
                bannedBehaviors = it.bannedBehaviors,
                maxReplyChars = it.maxReplyChars,
            )
        },
        entries = messages.map { message ->
            RoomEntry.MessageEntry(
                message = message,
                referenced = message.references.firstOrNull()?.let { byId[it] },
            )
        },
        summary = summary,
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
        StoredParticipant(
            id = it.id,
            position = it.position,
            name = it.name,
            key = it.key,
            state = it.state,
            tagline = it.tagline,
            expertise = it.expertise,
            goal = it.goal,
            defaultStance = it.defaultStance,
            style = it.style,
            bannedBehaviors = it.bannedBehaviors,
            maxReplyChars = it.maxReplyChars,
        )
    },
    messages = entries.filterIsInstance<RoomEntry.MessageEntry>().map { it.message },
    summary = summary,
    lastSequence = lastSequence,
    savedAt = savedAt,
)
