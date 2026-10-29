package com.agentroundtable.app.data.cache

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.Upsert

/**
 * 圆桌缓存的单表结构。
 *
 * 完整现场以 JSON 存在一列里，字段与 iOS 的 `StoredRoomState` 一一对应；
 * 任何一端加字段时另一端只需改解码器，不会出现两端模型悄悄漂移。
 */
@Entity(tableName = "stored_rooms")
data class StoredRoomEntity(
    @PrimaryKey val roundtableId: String,
    val savedAt: Long,
    val payload: String,
)

/** 已删除圆桌的墓碑。必须先于物理删除写入，防止已删除内容在恢复时复活。 */
@Entity(tableName = "deleted_rooms")
data class DeletedRoomEntity(
    @PrimaryKey val roundtableId: String,
)

@Dao
interface RoomDao {
    @Query("SELECT * FROM stored_rooms WHERE roundtableId = :id")
    suspend fun load(id: String): StoredRoomEntity?

    @Query("SELECT * FROM stored_rooms ORDER BY savedAt DESC")
    suspend fun list(): List<StoredRoomEntity>

    @Upsert
    suspend fun upsert(entity: StoredRoomEntity)

    @Query("DELETE FROM stored_rooms WHERE roundtableId = :id")
    suspend fun remove(id: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun markDeleted(entity: DeletedRoomEntity)

    @Query("SELECT EXISTS(SELECT 1 FROM deleted_rooms WHERE roundtableId = :id)")
    suspend fun isDeleted(id: String): Boolean
}

@Database(
    entities = [StoredRoomEntity::class, DeletedRoomEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class RoundtableDatabase : RoomDatabase() {
    abstract fun roomDao(): RoomDao
}
