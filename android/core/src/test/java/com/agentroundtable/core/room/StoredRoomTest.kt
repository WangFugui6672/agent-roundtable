package com.agentroundtable.core.room

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StoredRoomTest {
    @Test
    fun `a room view survives a round trip through storage`() {
        val view = RoomView(
            roundtableId = "c0de",
            topic = "议题",
            status = "running",
            currentRound = 1,
            maxRounds = 2,
            participants = listOf(ParticipantView("p1", 0, "方案派", "advocate", "completed")),
            entries = listOf(
                RoomEntry.MessageEntry(message = message("m1"), referenced = null),
                RoomEntry.MessageEntry(message = message("m2", refs = listOf("m1")), referenced = message("m1")),
                RoomEntry.Notice(id = "n1", kind = NoticeKind.Thinking, agentName = "方案派"),
            ),
            lastSequence = 7,
        )

        val restored = view.toStoredRoom(savedAt = 1L).toRoomView()

        assertEquals("c0de", restored.roundtableId)
        assertEquals(7, restored.lastSequence)
        assertEquals(2, restored.entries.size, )
        // 状态提示是临时信息，恢复时丢弃，由重连后的事件重新产生。
        assertEquals(0, restored.entries.filterIsInstance<RoomEntry.Notice>().size)
        val second = restored.entries.filterIsInstance<RoomEntry.MessageEntry>()[1]
        assertEquals("m1", second.referenced?.id)
    }

    @Test
    fun `a reference to an unknown message degrades to no quote`() {
        val view = RoomView(
            roundtableId = "c0de",
            entries = listOf(RoomEntry.MessageEntry(message("m1", refs = listOf("missing")), null)),
            lastSequence = 3,
        )

        val restored = view.toStoredRoom(savedAt = 1L).toRoomView()

        assertNull(restored.entries.filterIsInstance<RoomEntry.MessageEntry>().single().referenced)
    }

    private fun message(id: String, refs: List<String> = emptyList()) = Message(
        id = id,
        author = MessageAuthor(type = "agent", name = "方案派"),
        body = "正文$id",
        references = refs,
    )
}
