package com.agentroundtable.core.turn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnFailureTest {
    @Test
    fun `transient provider failures are retryable`() {
        listOf(
            "provider_timeout",
            "provider_rate_limited",
            "provider_network",
            "provider_server_error",
            "provider_empty_reply",
            "provider_invalid_response",
        ).forEach { code ->
            assertTrue("$code 应可重试", FailureKind.retryable(code, null))
        }
    }

    @Test
    fun `configuration failures are not retryable`() {
        listOf(
            "provider_unauthorized",
            "provider_insufficient_balance",
            "provider_model_not_found",
            "provider_not_configured",
        ).forEach { code ->
            assertFalse("$code 不应重试", FailureKind.retryable(code, null))
        }
    }

    @Test
    fun `an unknown code defaults to non-retryable`() {
        assertFalse(FailureKind.retryable("something_new", null))
    }

    @Test
    fun `the server flag wins over local classification`() {
        assertTrue(FailureKind.retryable("provider_unauthorized", serverRetryable = true))
        assertFalse(FailureKind.retryable("provider_timeout", serverRetryable = false))
    }
}
