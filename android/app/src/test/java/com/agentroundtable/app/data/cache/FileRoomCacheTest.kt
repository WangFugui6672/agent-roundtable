package com.agentroundtable.app.data.cache

import com.agentroundtable.core.room.Message
import com.agentroundtable.core.room.MessageAuthor
import com.agentroundtable.core.room.StoredRoom
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

class FileRoomCacheTest {
    private lateinit var directory: Path
    private lateinit var cache: FileRoomCache

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("room-cache")
        cache = FileRoomCache(directory.toFile())
    }

    @After
    fun tearDown() {
        directory.toFile().deleteRecursively()
    }

    @Test
    fun `saved rooms can be loaded and listed by recency`() = runTest {
        cache.save(stored("a", savedAt = 10))
        cache.save(stored("b", savedAt = 20))

        assertEquals("a", cache.load("a")?.roundtableId)
        assertEquals(listOf("b", "a"), cache.list().map { it.roundtableId })
    }

    @Test
    fun `loading an unknown room returns null`() = runTest {
        assertNull(cache.load("missing"))
    }

    @Test
    fun `deleting writes a tombstone and removes the cached room`() = runTest {
        cache.save(stored("a", savedAt = 10))

        cache.delete("a")

        assertTrue(cache.isDeleted("a"))
        assertNull(cache.load("a"))
        assertTrue(cache.list().isEmpty())
    }

    @Test
    fun `a late write cannot resurrect a deleted room`() = runTest {
        cache.delete("a")

        cache.save(stored("a", savedAt = 30))

        assertNull(cache.load("a"))
        assertTrue(cache.list().isEmpty())
    }

    @Test
    fun `corrupt cache files are ignored instead of crashing`() = runTest {
        val rooms = directory.resolve("rooms").toFile().apply { mkdirs() }
        rooms.resolve("broken.json").writeText("{not json")

        assertTrue(cache.list().isEmpty())
        assertNull(cache.load("broken"))
        assertFalse(cache.isDeleted("broken"))
    }

    private fun stored(id: String, savedAt: Long) = StoredRoom(
        roundtableId = id,
        topic = "议题$id",
        status = "running",
        currentRound = 1,
        maxRounds = 2,
        participants = emptyList(),
        messages = listOf(
            Message(id = "m$id", author = MessageAuthor(type = "agent", name = "方案派"), body = "正文"),
        ),
        lastSequence = 3,
        savedAt = savedAt,
    )
}
