package com.agentroundtable.core.room

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoomProjectionTest {
    private val projection = RoomProjection()

    @Test
    fun `joined snapshot seeds participants and messages without advancing the cursor`() {
        val view = projection.present(joined(cursor = 0, lastSequence = 0), localCursor = null)

        assertEquals("c0de", view.roundtableId)
        assertEquals("议题", view.topic)
        assertEquals(3, view.participants.size)
        assertEquals("方案派", view.participants.first().name)
        assertEquals(1, view.entries.size)
        assertEquals(0, view.lastSequence)
    }

    @Test
    fun `joined uses the snapshot sequence as the initial cursor when there is no local record`() {
        val view = projection.present(joined(lastSequence = 42), localCursor = null)

        assertEquals(42, view.lastSequence)
    }

    @Test
    fun `joined never overrides a local cursor when the replay window is intact`() {
        val view = projection.present(joined(lastSequence = 99, cursorExpired = false), localCursor = 7)

        assertEquals(7, view.lastSequence)
        assertFalse(view.cursorExpired)
    }

    @Test
    fun `expired replay window resets the cursor to the snapshot sequence`() {
        val view = projection.present(
            joined(lastSequence = 99, cursorExpired = true, requestedCursor = 7),
            localCursor = 7,
        )

        assertEquals(99, view.lastSequence)
        assertTrue(view.cursorExpired)
    }

    @Test
    fun `duplicate events do not produce duplicate entries`() {
        projection.present(joined(), localCursor = 0)
        val event = messageEvent(sequence = 2, messageId = "m1")

        assertTrue(projection.apply(event))
        val afterFirst = projection.snapshot().entries.size
        assertFalse(projection.apply(event))

        assertEquals(afterFirst, projection.snapshot().entries.size)
    }

    @Test
    fun `unknown event type advances the cursor without adding an entry`() {
        projection.present(joined(), localCursor = 0)
        val before = projection.snapshot().entries.size

        val changed = projection.apply(eventOf("""{"future":"field"}""", "future.event", 5))

        assertTrue(changed)
        assertEquals(5, projection.snapshot().lastSequence)
        assertEquals(before, projection.snapshot().entries.size)
    }

    @Test
    fun `message keeps a reference to the earlier message it cites`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(messageEvent(sequence = 2, messageId = "m1"))
        projection.apply(
            messageEvent(sequence = 3, messageId = "m2", references = listOf("m1"), stance = "challenge"),
        )

        val entries = projection.snapshot().entries.filterIsInstance<RoomEntry.MessageEntry>()
        val second = entries.single { it.message.id == "m2" }
        assertNotNull(second.referenced)
        assertEquals("m1", second.referenced?.id)
        assertEquals(Stance.Challenge, Stance.fromWire(second.message.stance))
    }

    @Test
    fun `thinking and pass become notices in arrival order`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(eventOf("""{"round":1,"agent_id":"a","agent_name":"方案派"}""", "agent.thinking", 2))
        projection.apply(eventOf("""{"round":1,"agent_name":"质疑派"}""", "agent.passed", 3))

        val notices = projection.snapshot().entries.filterIsInstance<RoomEntry.Notice>()
        assertEquals(listOf(NoticeKind.Thinking, NoticeKind.Passed), notices.map { it.kind })
        assertEquals("方案派", notices[0].agentName)
    }

    @Test
    fun `failed turn exposes the retryable flag and readable reason`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(
            eventOf(
                """{"round":1,"agent_name":"体验派","failure_code":"provider_timeout",
                   "message":"请求超时，请稍后重试。","retryable":true}""",
                "agent.failed",
                4,
            ),
        )

        val notice = projection.snapshot().entries.filterIsInstance<RoomEntry.Notice>().single()
        assertEquals(NoticeKind.Failed, notice.kind)
        assertEquals("请求超时，请稍后重试。", notice.detail)
        assertTrue(notice.retryable)
    }

    @Test
    fun `a partial failure keeps the generated text separate from a completed message`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(
            eventOf(
                """{"round":1,"agent_name":"体验派","failure_code":"provider_timeout",
                   "message":"请求超时。","retryable":true,"partial":"已经生成的半段观点"}""",
                "agent.failed",
                8,
            ),
        )

        val notice = projection.snapshot().entries.filterIsInstance<RoomEntry.Notice>().single()
        assertEquals("已经生成的半段观点", notice.partial)
        assertTrue(notice.retryable)
        // 部分输出不产生普通发言。
        assertEquals(0, projection.snapshot().entries.filterIsInstance<RoomEntry.MessageEntry>().count { it.message.body == "已经生成的半段观点" })
    }

    @Test
    fun `a non-retryable failure offers no retry`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(
            eventOf(
                """{"round":1,"agent_name":"方案派","failure_code":"provider_unauthorized",
                   "message":"API Key 无效。","retryable":false}""",
                "agent.failed",
                9,
            ),
        )

        val notice = projection.snapshot().entries.filterIsInstance<RoomEntry.Notice>().single()
        assertFalse(notice.retryable)
    }

    @Test
    fun `pause and resume change the roundtable status`() {
        projection.present(joined(), localCursor = 0)
        projection.apply(eventOf("""{"status":"paused"}""", "room.paused", 5))
        assertEquals("paused", projection.snapshot().status)

        projection.apply(eventOf("""{"status":"running"}""", "room.resumed", 6))
        assertEquals("running", projection.snapshot().status)
    }

    @Test
    fun `malformed payload is ignored without breaking the cursor`() {
        projection.present(joined(), localCursor = 0)

        val before = projection.snapshot().entries.size

        projection.apply(eventOf("""{"message":{"not":"a message"}}""", "message.completed", 7))

        assertEquals(before, projection.snapshot().entries.size)
        assertEquals(7, projection.snapshot().lastSequence)
    }

    @Test
    fun `seen event ids are bounded`() {
        val bounded = RoomProjection(maxSeenEventIds = 2)
        bounded.present(joined(), localCursor = 0)
        bounded.apply(eventOf("""{}""", "agent.typing", 1))
        bounded.apply(eventOf("""{}""", "agent.typing", 2))
        bounded.apply(eventOf("""{}""", "agent.typing", 3))

        // 最早的事件 ID 已被淘汰，重放它会再次被处理，但不会重复推进游标语义之外的可见状态。
        assertFalse(bounded.apply(eventOf("""{}""", "agent.typing", 3)))
    }

    @Test
    fun `joined with no messages yields an empty entry list`() {
        val view = projection.present(joined(messages = false), localCursor = null)

        assertTrue(view.entries.isEmpty())
        assertNull(view.diagnostic)
    }

    private fun joined(
        cursor: Int = 0,
        lastSequence: Int = 0,
        cursorExpired: Boolean = false,
        requestedCursor: Int? = null,
        messages: Boolean = true,
    ): RoomJoinedPayload {
        val messageJson = if (messages) messageJson("m0", "决策A") else ""
        val requested = requestedCursor?.toString() ?: "null"
        val raw = """
            {"event_id":"joined","room_id":"c0de","sequence":0,"created_at":"2026-10-26T01:02:03.456Z",
             "event_type":"room.joined",
             "payload":{"roundtable":{"id":"c0de","topic":"议题","status":"ready","current_round":0,
               "max_rounds":2,"last_sequence":$lastSequence,
               "participants":[
                 {"id":"p1","position":0,"state":"waiting","agent":{"id":"a1","key":"advocate","name":"方案派",
                  "tagline":"t","expertise":"e","goal":"g","default_stance":"d","style":"s"}},
                 {"id":"p2","position":1,"state":"waiting","agent":{"id":"a2","key":"skeptic","name":"质疑派",
                  "tagline":"t","expertise":"e","goal":"g","default_stance":"d","style":"s"}},
                 {"id":"p3","position":2,"state":"waiting","agent":{"id":"a3","key":"experience","name":"体验派",
                  "tagline":"t","expertise":"e","goal":"g","default_stance":"d","style":"s"}}]},
              "messages":[$messageJson],
              "failures":[],
              "summary":null,
              "replay":{"requested_cursor":$requested,"oldest_sequence":null,
                        "latest_sequence":$lastSequence,"window_days":90,"cursor_expired":$cursorExpired}}}
        """.trimIndent()
        return EventEnvelope.decodeJoined(raw)!!
    }

    private fun messageJson(id: String, body: String, references: List<String> = emptyList(), stance: String? = null) =
        """{"id":"$id","turn_id":null,"round_number":1,
            "author":{"type":"agent","roundtable_agent_id":"p1","agent_key":"advocate","name":"方案派"},
            "message_type":"proposal","claim":"主张","body":"$body","stance":${stance?.let { "\"$it\"" } ?: "null"},
            "references":[${references.joinToString(",") { "\"$it\"" }}],
            "challenge_target_agent_id":null,"confidence":0.6,"mentioned_agent_ids":[],
            "is_key_point":false,"supersedes_message_id":null,"superseded_by_message_id":null,
            "created_at":"2026-10-26T01:02:03.456Z"}"""

    private fun messageEvent(
        sequence: Int,
        messageId: String,
        references: List<String> = emptyList(),
        stance: String? = null,
    ) = eventOf(
        """{"message":${messageJson(messageId, "正文$messageId", references, stance)}}""",
        "message.completed",
        sequence,
        eventId = "e$sequence-$messageId",
    )

    private fun eventOf(
        payload: String,
        type: String,
        sequence: Int,
        eventId: String = "e$sequence-$type",
    ) = EventEnvelope.decode(
        """{"event_id":"$eventId","room_id":"c0de","sequence":$sequence,
            "created_at":"2026-10-26T01:02:03.456Z","event_type":"$type","payload":$payload}"""
            .trimIndent(),
    )!!
}
