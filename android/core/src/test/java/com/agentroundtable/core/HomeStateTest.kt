package com.agentroundtable.core

import org.junit.Assert.assertEquals
import org.junit.Test

class HomeStateTest {
    @Test
    fun `empty home state has a single stable instance`() {
        val first: HomeState = HomeState.Empty
        val second: HomeState = HomeState.Empty

        assertEquals(first, second)
    }
}
