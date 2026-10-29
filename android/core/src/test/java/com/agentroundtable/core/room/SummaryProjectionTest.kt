package com.agentroundtable.core.room

import com.agentroundtable.core.model.RoundSummary
import com.agentroundtable.core.model.SummaryItem
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SummaryProjectionTest {
    private val projection = RoomProjection()
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `joined snapshot restores an existing summary`() {
        val view = projection.present(joined(summaryJson(version = 2)), localCursor = null)

        assertEquals(2, view.summary?.version)
        assertEquals(listOf("m1"), view.summary?.consensus?.single()?.referenceMessageIds)
    }

    @Test
    fun `summary completed event stores the summary and completes the room`() {
        projection.present(joined(summary = null), localCursor = 0)

        assertTrue(projection.apply(eventOf(summaryJson(version = 1), "summary.completed", 5)))

        val view = projection.snapshot()
        assertEquals("completed", view.status)
        assertEquals(1, view.summary?.version)
        assertEquals(5, view.lastSequence)
    }

    @Test
    fun `an idempotent response without events still updates the summary and status`() {
        projection.present(joined(summary = null), localCursor = 0)

        val changed = projection.applySummary(
            summary = summary(version = 1),
            status = "completed",
            currentRound = 2,
        )

        assertTrue(changed)
        val view = projection.snapshot()
        assertEquals("completed", view.status)
        assertEquals(1, view.summary?.version)
        assertEquals(2, view.currentRound)
    }

    @Test
    fun `a summary survives a cache round trip`() {
        projection.present(joined(summary = null), localCursor = 0)
        projection.applySummary(summary(version = 3), status = "completed")

        val restored = projection.snapshot().toStoredRoom(savedAt = 1L).toRoomView()

        assertEquals(3, restored.summary?.version)
        assertEquals("completed", restored.status)
    }

    @Test
    fun `old cache payloads without a summary still decode`() {
        val stored = json.decodeFromString<StoredRoom>(
            """{"roundtableId":"r","topic":"议题","status":"running","currentRound":1,
                "maxRounds":2,"participants":[],"messages":[],"lastSequence":4,"savedAt":1}""",
        )

        assertNull(stored.summary)
        assertNull(stored.toRoomView().summary)
    }

    private fun summary(version: Int) = RoundSummary(
        id = "summary-1",
        version = version,
        degraded = false,
        consensus = listOf(SummaryItem("先做实验", listOf("m1"))),
        createdAt = "2026-10-26T01:05:03.456Z",
        updatedAt = "2026-10-26T01:05:03.456Z",
    )

    private fun summaryJson(version: Int) = """
        {"id":"summary-1","version":$version,"degraded":false,
         "consensus":[{"text":"先做实验","reference_message_ids":["m1"]}],
         "dissent":[],"recommendations":[],"unresolved":[],
         "created_at":"2026-10-26T01:05:03.456Z","updated_at":"2026-10-26T01:05:03.456Z"}
    """.trimIndent()

    private fun joined(summary: String?): RoomJoinedPayload = EventEnvelope.decodeJoined(
        """{"event_id":"joined","room_id":"c0de","sequence":0,
            "created_at":"2026-10-26T01:02:03.456Z","event_type":"room.joined",
            "payload":{"roundtable":{"id":"c0de","topic":"议题","status":"completed",
              "current_round":2,"max_rounds":2,"last_sequence":4,"participants":[]},
              "messages":[],
              "summary":${summary ?: "null"},
              "replay":{"requested_cursor":0,"oldest_sequence":null,
                        "latest_sequence":4,"window_days":90,"cursor_expired":false}}}
        """.trimIndent(),
    )!!

    private fun eventOf(payload: String, type: String, sequence: Int) = EventEnvelope.decode(
        """{"event_id":"e$sequence","room_id":"c0de","sequence":$sequence,
            "created_at":"2026-10-26T01:02:03.456Z","event_type":"$type",
            "payload":{"summary":$payload}}""",
    )!!
}
