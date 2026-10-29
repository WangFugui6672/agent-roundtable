package com.agentroundtable.core.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LocalInferencePolicyTest {
    private val model = LocalModelCatalog.qwen05bQ4Km

    @Test
    fun `64-bit device with enough memory is available`() {
        val device = LocalDeviceCapability(
            is64Bit = true,
            availableMemoryBytes = LocalInferencePolicy.requiredMemoryBytes(model) + 1,
            lowMemory = false,
        )

        assertEquals(LocalAvailability.Available, LocalInferencePolicy.availability(model, device))
    }

    @Test
    fun `32-bit device is disabled with an explicit reason`() {
        val device = LocalDeviceCapability(
            is64Bit = false,
            availableMemoryBytes = Long.MAX_VALUE,
            lowMemory = false,
        )

        val availability = LocalInferencePolicy.availability(model, device)
        assertTrue(availability is LocalAvailability.Disabled)
        assertTrue((availability as LocalAvailability.Disabled).reason.contains("64 位"))
    }

    @Test
    fun `low memory is disabled even when available bytes look sufficient`() {
        val device = LocalDeviceCapability(
            is64Bit = true,
            availableMemoryBytes = Long.MAX_VALUE,
            lowMemory = true,
        )

        val availability = LocalInferencePolicy.availability(model, device)
        assertTrue(availability is LocalAvailability.Disabled)
        assertTrue((availability as LocalAvailability.Disabled).reason.contains("低内存"))
    }

    @Test
    fun `insufficient memory reports required and available amounts`() {
        val device = LocalDeviceCapability(
            is64Bit = true,
            availableMemoryBytes = 128L * 1024 * 1024,
            lowMemory = false,
        )

        val availability = LocalInferencePolicy.availability(model, device)
        assertTrue(availability is LocalAvailability.Disabled)
        val reason = (availability as LocalAvailability.Disabled).reason
        assertTrue(reason.contains("可用内存不足"))
        assertTrue(reason.contains("128 MB"))
    }

    @Test
    fun `required memory includes a working set margin`() {
        assertEquals(
            model.sizeBytes + LocalInferencePolicy.WORKING_SET_OVERHEAD_BYTES,
            LocalInferencePolicy.requiredMemoryBytes(model),
        )
    }
}

class LocalInferenceMetricsTest {
    @Test
    fun `decode speed excludes the first token`() {
        val metrics = LocalInferenceMetrics(
            modelLoadMs = 1200,
            firstTokenMs = 300,
            generatedTokens = 11,
            decodeMs = 2000,
            peakMemoryBytes = 600L * 1024 * 1024,
            modelFileBytes = 491_400_032L,
        )

        assertEquals(5.0, metrics.tokensPerSecond, 0.0001)
    }

    @Test
    fun `single token reports zero decode speed instead of dividing by zero`() {
        val metrics = LocalInferenceMetrics(
            modelLoadMs = 100,
            firstTokenMs = 50,
            generatedTokens = 1,
            decodeMs = 0,
            peakMemoryBytes = 0,
            modelFileBytes = 0,
        )

        assertEquals(0.0, metrics.tokensPerSecond, 0.0001)
    }
}

class LocalPromptTest {
    @Test
    fun `qwen prompt uses chatml roles and generation prefix`() {
        val prompt = LocalPrompt.qwenChatMl("你是助手。", "你好")

        assertEquals(
            "<|im_start|>system\n你是助手。<|im_end|>\n" +
                "<|im_start|>user\n你好<|im_end|>\n" +
                "<|im_start|>assistant\n",
            prompt,
        )
    }
}

class Sha256Test {
    @Test
    fun `empty input matches the known sha256 vector`() {
        val file = File.createTempFile("sha256", ".bin")
        try {
            assertEquals(
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                Sha256.hex(file),
            )
        } finally {
            file.delete()
        }
    }

    @Test
    fun `abc matches the known sha256 vector`() {
        val file = Files.createTempFile("sha256", ".bin").toFile()
        try {
            file.writeText("abc")
            assertEquals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                Sha256.hex(file),
            )
            assertTrue(Sha256.matches(file, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `missing file does not match`() {
        assertEquals(false, Sha256.matches(File("/definitely/not/here.gguf"), "00"))
    }
}
