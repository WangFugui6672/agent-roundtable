package com.agentroundtable.app.data.knowledge

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * 资料库的本地表结构。
 *
 * 与圆桌缓存分开建库（`knowledge.db`），资料库的迁移不会影响历史圆桌；
 * 文档块通过外键跟随文档级联删除，删除文档时不会留下无法管理的残留。
 * 文档块向量单独存表：向量化失败时旧向量保持不变，文档本身仍可正常使用。
 */
@Entity(tableName = "knowledge_documents")
data class KnowledgeDocumentEntity(
    @PrimaryKey val id: String,
    val name: String,
    val format: String,
    val chunkCount: Int,
    val importedAt: Long,
)

@Entity(
    tableName = "document_chunks",
    primaryKeys = ["documentId", "chunkIndex"],
    foreignKeys = [
        ForeignKey(
            entity = KnowledgeDocumentEntity::class,
            parentColumns = ["id"],
            childColumns = ["documentId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("documentId")],
)
data class DocumentChunkEntity(
    val documentId: String,
    val chunkIndex: Int,
    val text: String,
)

@Entity(
    tableName = "chunk_vectors",
    primaryKeys = ["documentId", "chunkIndex"],
    foreignKeys = [
        ForeignKey(
            entity = KnowledgeDocumentEntity::class,
            parentColumns = ["id"],
            childColumns = ["documentId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("documentId")],
)
data class ChunkVectorEntity(
    val documentId: String,
    val chunkIndex: Int,
    val embedding: ByteArray,
    val dimension: Int,
)

@Dao
interface KnowledgeDao {
    @Query("SELECT * FROM knowledge_documents ORDER BY importedAt DESC")
    suspend fun documents(): List<KnowledgeDocumentEntity>

    @Query("SELECT * FROM document_chunks WHERE documentId = :documentId ORDER BY chunkIndex")
    suspend fun chunks(documentId: String): List<DocumentChunkEntity>

    @Query("SELECT * FROM chunk_vectors WHERE documentId = :documentId ORDER BY chunkIndex")
    suspend fun vectors(documentId: String): List<ChunkVectorEntity>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertDocument(document: KnowledgeDocumentEntity)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertChunks(chunks: List<DocumentChunkEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertVectors(vectors: List<ChunkVectorEntity>)

    @Query("DELETE FROM chunk_vectors WHERE documentId = :documentId")
    suspend fun deleteVectors(documentId: String)

    @Query("DELETE FROM document_chunks WHERE documentId = :documentId")
    suspend fun deleteChunks(documentId: String)

    @Query("DELETE FROM knowledge_documents WHERE id = :documentId")
    suspend fun deleteDocument(documentId: String)
}

@Database(
    entities = [
        KnowledgeDocumentEntity::class,
        DocumentChunkEntity::class,
        ChunkVectorEntity::class,
    ],
    version = 2,
    exportSchema = false,
)
abstract class KnowledgeDatabase : RoomDatabase() {
    abstract fun knowledgeDao(): KnowledgeDao

    companion object {
        /** #32 新增文档块向量表；已有文档保持原样，稍后由后台补做向量化。 */
        val MIGRATION_1_2: Migration = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `chunk_vectors` (" +
                        "`documentId` TEXT NOT NULL, " +
                        "`chunkIndex` INTEGER NOT NULL, " +
                        "`embedding` BLOB NOT NULL, " +
                        "`dimension` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`documentId`, `chunkIndex`), " +
                        "FOREIGN KEY(`documentId`) REFERENCES `knowledge_documents`(`id`) " +
                        "ON UPDATE NO ACTION ON DELETE CASCADE)",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_chunk_vectors_documentId` " +
                        "ON `chunk_vectors` (`documentId`)",
                )
            }
        }
    }
}
