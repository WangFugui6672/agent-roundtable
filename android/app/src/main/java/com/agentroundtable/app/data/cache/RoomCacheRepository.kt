package com.agentroundtable.app.data.cache

import androidx.room.withTransaction
import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.StoredRoom
import kotlinx.serialization.json.Json

/** Room 实现的圆桌缓存。 */
class RoomCacheRepository(
    private val database: RoundtableDatabase,
) : RoomCache {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun load(roundtableId: String): StoredRoom? {
        if (isDeleted(roundtableId)) return null
        val entity = database.roomDao().load(roundtableId) ?: return null
        return decode(entity.payload)
    }

    override suspend fun save(room: StoredRoom) {
        // 墓碑优先：已删除的圆桌不得被迟到的写入复活。
        if (isDeleted(room.roundtableId)) return
        database.roomDao().upsert(
            StoredRoomEntity(
                roundtableId = room.roundtableId,
                savedAt = room.savedAt,
                payload = json.encodeToString(StoredRoom.serializer(), room),
            ),
        )
    }

    override suspend fun list(): List<StoredRoom> =
        database.roomDao().list().mapNotNull { entity ->
            if (isDeleted(entity.roundtableId)) null else decode(entity.payload)
        }

    /** 写墓碑与删除数据在同一事务内完成，不存在只完成一半的中间态。 */
    override suspend fun delete(roundtableId: String) {
        database.withTransaction {
            database.roomDao().markDeleted(DeletedRoomEntity(roundtableId))
            database.roomDao().remove(roundtableId)
        }
    }

    override suspend fun isDeleted(roundtableId: String): Boolean =
        database.roomDao().isDeleted(roundtableId)

    private fun decode(payload: String): StoredRoom? = try {
        json.decodeFromString<StoredRoom>(payload)
    } catch (error: Exception) {
        null
    }
}
