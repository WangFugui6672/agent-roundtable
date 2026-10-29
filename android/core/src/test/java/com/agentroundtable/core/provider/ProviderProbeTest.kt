package com.agentroundtable.core.provider

import com.agentroundtable.core.api.FakeTransport
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderProbeTest {
    private val transport = FakeTransport()
    private val probe = ProviderProbe(transport)
    private val config = ProviderConfiguration(ProviderKind.DeepSeek, "https://api.deepseek.com/v1", "deepseek-chat")

    @Test
    fun `a healthy provider reports the number of models`() = runTest {
        transport.enqueue(200, """{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}""")

        val outcome = probe.check(config, "sk-test")

        assertEquals(ProviderCheckOutcome.Ok(modelCount = 2), outcome)
        val request = transport.requests.single()
        assertEquals("https://api.deepseek.com/v1/models", request.url)
        assertEquals("Bearer sk-test", request.headers["Authorization"])
    }

    @Test
    fun `401 means the key is invalid`() = runTest {
        transport.enqueue(401, "unauthorized")

        assertEquals(ProviderCheckOutcome.InvalidKey, probe.check(config, "sk-bad"))
    }

    @Test
    fun `403 also means the key is invalid`() = runTest {
        transport.enqueue(403, "forbidden")

        assertEquals(ProviderCheckOutcome.InvalidKey, probe.check(config, "sk-bad"))
    }

    @Test
    fun `a model missing from the listing is reported explicitly`() = runTest {
        transport.enqueue(200, """{"data":[{"id":"other-model"}]}""")

        val outcome = probe.check(config, "sk-test")

        assertEquals(ProviderCheckOutcome.ModelMissing("deepseek-chat"), outcome)
    }

    @Test
    fun `transport failure is reported as unreachable`() = runTest {
        transport.throwOnNext = java.io.IOException("no route to host")

        val outcome = probe.check(config, "sk-test")

        assertTrue(outcome is ProviderCheckOutcome.Unreachable)
    }

    @Test
    fun `a provider without a data array still counts as reachable`() = runTest {
        transport.enqueue(200, "ok")

        assertEquals(ProviderCheckOutcome.Ok(modelCount = null), probe.check(config, "sk-test"))
    }

    @Test
    fun `other status codes surface the http status`() = runTest {
        transport.enqueue(500, "boom")

        val outcome = probe.check(config, "sk-test")

        assertTrue(outcome is ProviderCheckOutcome.Failed)
        assertTrue((outcome as ProviderCheckOutcome.Failed).reason.contains("500"))
    }
}
