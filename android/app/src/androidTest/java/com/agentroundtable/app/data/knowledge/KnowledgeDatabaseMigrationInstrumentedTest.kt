package com.agentroundtable.app.data.knowledge

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** 验证 #31 的 v1 资料库升级到 #32 的 v2 后文档仍在，且新向量表可用。 */
@RunWith(AndroidJUnit4::class)
class KnowledgeDatabaseMigrationInstrumentedTest {
    @Test
    fun migrateFromV1KeepsDocumentsAndCreatesVectorTable() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "knowledge-migration-test.db"
        context.deleteDatabase(databaseName)
        createVersion1Database(context, databaseName)

        val database = Room.databaseBuilder(
            context,
            KnowledgeDatabase::class.java,
            databaseName,
        )
            .addMigrations(KnowledgeDatabase.MIGRATION_1_2)
            .build()

        try {
            val dao = database.knowledgeDao()
            assertEquals(1, dao.documents().size)
            assertEquals(2, dao.chunks("doc-1").size)

            dao.insertVectors(
                listOf(
                    ChunkVectorEntity(
                        documentId = "doc-1",
                        chunkIndex = 0,
                        embedding = ByteArray(8),
                        dimension = 2,
                    ),
                ),
            )
            assertEquals(1, dao.vectors("doc-1").size)

            dao.deleteDocument("doc-1")

            assertEquals(0, dao.vectors("doc-1").size)
            assertEquals(0, dao.chunks("doc-1").size)
        } finally {
            database.close()
            context.deleteDatabase(databaseName)
        }
    }

    private fun createVersion1Database(context: Context, databaseName: String) {
        val configuration = SupportSQLiteOpenHelper.Configuration.builder(context)
            .name(databaseName)
            .callback(
                object : SupportSQLiteOpenHelper.Callback(1) {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        db.execSQL(
                            "CREATE TABLE IF NOT EXISTS `knowledge_documents` (" +
                                "`id` TEXT NOT NULL, `name` TEXT NOT NULL, " +
                                "`format` TEXT NOT NULL, `chunkCount` INTEGER NOT NULL, " +
                                "`importedAt` INTEGER NOT NULL, PRIMARY KEY(`id`))",
                        )
                        db.execSQL(
                            "CREATE TABLE IF NOT EXISTS `document_chunks` (" +
                                "`documentId` TEXT NOT NULL, `chunkIndex` INTEGER NOT NULL, " +
                                "`text` TEXT NOT NULL, PRIMARY KEY(`documentId`, `chunkIndex`), " +
                                "FOREIGN KEY(`documentId`) REFERENCES `knowledge_documents`(`id`) " +
                                "ON UPDATE NO ACTION ON DELETE CASCADE)",
                        )
                        db.execSQL(
                            "CREATE INDEX IF NOT EXISTS `index_document_chunks_documentId` " +
                                "ON `document_chunks` (`documentId`)",
                        )
                        db.execSQL(
                            "INSERT INTO `knowledge_documents` " +
                                "(`id`, `name`, `format`, `chunkCount`, `importedAt`) " +
                                "VALUES ('doc-1', '旧文档.txt', 'txt', 2, 1)",
                        )
                        db.execSQL(
                            "INSERT INTO `document_chunks` (`documentId`, `chunkIndex`, `text`) " +
                                "VALUES ('doc-1', 0, '旧内容一'), ('doc-1', 1, '旧内容二')",
                        )
                    }

                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                },
            )
            .build()

        val helper = FrameworkSQLiteOpenHelperFactory().create(configuration)
        try {
            helper.writableDatabase
        } finally {
            helper.close()
        }
    }
}
