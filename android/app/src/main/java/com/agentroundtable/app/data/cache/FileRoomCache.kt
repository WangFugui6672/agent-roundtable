package com.agentroundtable.app.data.cache

import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.StoredRoom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * 文件实现的圆桌缓存。
 *
 * 每张圆桌一个 JSON 文件，字段与 iOS 的 `StoredRoomState` 一一对应；
 * 墓碑是独立文件，且必须先于数据文件删除写入，已删除的圆桌不会被恢复。
 *
 * 选择文件而不是数据库的原因是构建链：AGP 9 的内置 Kotlin 下注解处理器下载不可靠，
 * 这里先用零依赖实现把语义跑通，后续可替换为 Room 而不影响上层。
 */
class FileRoomCache(private val directory: File) : RoomCache {
    private val json = Json { ignoreUnknownKeys = true }

    private val roomsDir: File get() = File(directory, "rooms").apply { mkdirs() }

    private val tombstonesDir: File get() = File(directory, "deleted").apply { mkdirs() }

    override suspend fun load(roundtableId: String): StoredRoom? = withContext(Dispatchers.IO) {
        if (isDeleted(roundtableId)) return@withContext null
        val file = roomFile(roundtableId)
        if (!file.exists()) return@withContext null
        try {
            json.decodeFromString<StoredRoom>(file.readText())
        } catch (error: Exception) {
            null
        }
    }

    override suspend fun save(room: StoredRoom) = withContext(Dispatchers.IO) {
        // 墓碑优先：已删除的圆桌不得被迟到的写入复活。
        if (isDeleted(room.roundtableId)) return@withContext
        val target = roomFile(room.roundtableId)
        val temp = File(target.parentFile, target.name + ".tmp")
        temp.writeText(json.encodeToString(StoredRoom.serializer(), room))
        if (!temp.renameTo(target)) {
            target.writeText(temp.readText())
            temp.delete()
        }
    }

    override suspend fun list(): List<StoredRoom> = withContext(Dispatchers.IO) {
        roomsDir.listFiles()
            ?.filter { it.isFile && it.name.endsWith(JSON_SUFFIX) }
            ?.mapNotNull { file ->
                val id = file.name.removeSuffix(JSON_SUFFIX)
                if (isDeleted(id)) {
                    null
                } else {
                    try {
                        json.decodeFromString<StoredRoom>(file.readText())
                    } catch (error: Exception) {
                        null
                    }
                }
            }
            ?.sortedByDescending { it.savedAt }
            ?: emptyList()
    }

    override suspend fun delete(roundtableId: String) = withContext(Dispatchers.IO) {
        tombstoneFile(roundtableId).writeText(roundtableId)
        roomFile(roundtableId).delete()
        Unit
    }

    override suspend fun isDeleted(roundtableId: String): Boolean = withContext(Dispatchers.IO) {
        tombstoneFile(roundtableId).exists()
    }

    private fun roomFile(roundtableId: String) = File(roomsDir, "$roundtableId$JSON_SUFFIX")

    private fun tombstoneFile(roundtableId: String) = File(tombstonesDir, roundtableId)

    private companion object {
        const val JSON_SUFFIX = ".json"
    }
}
