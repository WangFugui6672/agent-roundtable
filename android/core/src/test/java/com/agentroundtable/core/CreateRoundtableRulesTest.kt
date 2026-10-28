package com.agentroundtable.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CreateRoundtableRulesTest {
    @Test
    fun `blank topic is rejected`() {
        assertTrue(CreateRoundtableRules.validateTopic("   ") is CreateValidation.Invalid)
    }

    @Test
    fun `topic of exactly one character is accepted`() {
        assertEquals(CreateValidation.Valid, CreateRoundtableRules.validateTopic("问"))
    }

    @Test
    fun `topic of exactly 500 characters is accepted`() {
        assertEquals(CreateValidation.Valid, CreateRoundtableRules.validateTopic("议".repeat(500)))
    }

    @Test
    fun `topic longer than 500 characters is rejected`() {
        assertTrue(CreateRoundtableRules.validateTopic("议".repeat(501)) is CreateValidation.Invalid)
    }

    @Test
    fun `exactly three distinct agents are required`() {
        assertEquals(CreateValidation.Valid, CreateRoundtableRules.validateSelection(listOf("a", "b", "c")))
        assertTrue(CreateRoundtableRules.validateSelection(listOf("a", "b")) is CreateValidation.Invalid)
        assertTrue(CreateRoundtableRules.validateSelection(listOf("a", "b", "c", "d")) is CreateValidation.Invalid)
        assertTrue(CreateRoundtableRules.validateSelection(listOf("a", "a", "b")) is CreateValidation.Invalid)
    }
}
