package com.agentroundtable.core.provider

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class MemorySecretStore : SecretStore {
    val values = mutableMapOf<String, String>()

    override suspend fun read(name: String): String? = values[name]

    override suspend fun write(name: String, value: String) {
        values[name] = value
    }

    override suspend fun delete(name: String) {
        values.remove(name)
    }
}

private class MemoryConfigStorage(var configuration: ProviderConfiguration? = null) :
    ProviderConfigurationStorage {
    override suspend fun read(): ProviderConfiguration? = configuration

    override suspend fun write(configuration: ProviderConfiguration) {
        this.configuration = configuration
    }

    override suspend fun clear() {
        configuration = null
    }
}

private class MemoryNoticeStore(private var acknowledged: Boolean = false) : NoticeStore {
    override suspend fun isAcknowledged(): Boolean = acknowledged

    override suspend fun acknowledge() {
        acknowledged = true
    }
}

class ProviderSettingsTest {
    private val secrets = MemorySecretStore()
    private val storage = MemoryConfigStorage()
    private val notices = MemoryNoticeStore()
    private val settings = ProviderSettings(storage, secrets, notices)

    private val deepSeek = ProviderConfiguration(ProviderKind.DeepSeek, "https://api.deepseek.com/v1", "deepseek-chat")

    @Test
    fun `saving a provider stores the key outside the configuration`() = runTest {
        val result = settings.save(deepSeek, "sk-test")

        assertEquals(ProviderSaveResult.Saved, result)
        assertEquals("sk-test", secrets.values[ProviderSettings.API_KEY_NAME])
        assertEquals("https://api.deepseek.com/v1", storage.configuration?.baseUrl)
        assertTrue(settings.load().isComplete)
    }

    @Test
    fun `changing the base url requires a new key`() = runTest {
        settings.save(deepSeek, "sk-old")

        val result = settings.save(
            deepSeek.copy(baseUrl = "https://example.com/v1"),
            apiKey = null,
        )

        assertTrue(result is ProviderSaveResult.KeyRequired)
        assertEquals("https://api.deepseek.com/v1", storage.configuration?.baseUrl)
    }

    @Test
    fun `changing only the model keeps the existing key`() = runTest {
        settings.save(deepSeek, "sk-old")

        val result = settings.save(deepSeek.copy(model = "deepseek-reasoner"), apiKey = null)

        assertEquals(ProviderSaveResult.Saved, result)
        assertEquals("sk-old", secrets.values[ProviderSettings.API_KEY_NAME])
        assertEquals("deepseek-reasoner", storage.configuration?.model)
    }

    @Test
    fun `invalid base url is rejected before anything is written`() = runTest {
        val result = settings.save(deepSeek.copy(baseUrl = "api.deepseek.com"), "sk-test")

        assertTrue(result is ProviderSaveResult.Invalid)
        assertNull(storage.configuration)
        assertTrue(secrets.values.isEmpty())
    }

    @Test
    fun `base url with query parameters is rejected`() = runTest {
        val result = settings.save(deepSeek.copy(baseUrl = "https://api.deepseek.com/v1?key=1"), "sk-test")

        assertTrue(result is ProviderSaveResult.Invalid)
    }

    @Test
    fun `deleting a provider removes the key as well`() = runTest {
        settings.save(deepSeek, "sk-test")

        settings.delete()

        assertNull(storage.configuration)
        assertTrue(secrets.values.isEmpty())
        assertFalse(settings.load().isComplete)
    }

    @Test
    fun `a configuration without a key is not considered complete`() = runTest {
        storage.configuration = deepSeek

        val state = settings.load()

        assertFalse(state.hasKey)
        assertFalse(state.isComplete)
    }

    @Test
    fun `the third party notice starts unacknowledged and can be acknowledged`() = runTest {
        assertFalse(settings.load().noticeAcknowledged)

        settings.acknowledgeNotice()

        assertTrue(settings.load().noticeAcknowledged)
    }

    @Test
    fun `base url trailing slash is normalised`() = runTest {
        settings.save(deepSeek.copy(baseUrl = "https://api.deepseek.com/v1/"), "sk-test")

        assertEquals("https://api.deepseek.com/v1", storage.configuration?.baseUrl)
    }
}
