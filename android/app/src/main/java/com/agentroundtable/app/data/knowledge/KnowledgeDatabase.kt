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

/**
 * 资料库的本地表结构。
 *
 * 与圆桌缓存分开建库（`knowledge.db`），资料库的迁移不会影响历史圆桌；
 * 文档块通过外键跟随文档级联删除，删除文档时不会留下无法管理的残留。
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

@Dao
interface KnowledgeDao {
    @Query("SELECT * FROM knowledge_documents ORDER BY importedAt DESC")
    suspend fun documents(): List<KnowledgeDocumentEntity>

    @Query("SELECT * FROM document_chunks WHERE documentId = :documentId ORDER BY chunkIndex")
    suspend fun chunks(documentId: String): List<DocumentChunkEntity>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertDocument(document: KnowledgeDocumentEntity)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertChunks(chunks: List<DocumentChunkEntity>)

    @Query("DELETE FROM document_chunks WHERE documentId = :documentId")
    suspend fun deleteChunks(documentId: String)

    @Query("DELETE FROM knowledge_documents WHERE id = :documentId")
    suspend fun deleteDocument(documentId: String)
}

@Database(
    entities = [KnowledgeDocumentEntity::class, DocumentChunkEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class KnowledgeDatabase : RoomDatabase() {
    abstract fun knowledgeDao(): KnowledgeDao
}
