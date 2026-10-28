package com.agentroundtable.app.local

import android.net.Uri
import com.agentroundtable.core.local.LocalDeviceCapability
import com.agentroundtable.core.local.LocalEngineState
import com.agentroundtable.core.local.LocalInferenceEngine
import com.agentroundtable.core.local.LocalInferenceEvent
import com.agentroundtable.core.local.LocalInferenceMetrics
import com.agentroundtable.core.local.LocalLoadResult
import com.agentroundtable.core.local.LocalModel
import com.agentroundtable.core.local.LocalModelCatalog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

private class FakeStore(private val verified: Boolean = true) : LocalModelStore {
    override fun fileFor(model: LocalModel): File = File("/tmp/${model.fileName}")

    override fun isVerified(model: LocalModel): Boolean = verified

    override suspend fun verify(model: LocalModel): Boolean = verified

    override suspend fun download(model: LocalModel, onProgress: (Float) -> Unit): File {
        onProgress(1f)
        return fileFor(model)
    }

    override suspend fun import(uri: Uri): LocalModel? = null
}

private class FakeDevice(
    private val capability: LocalDeviceCapability = LocalDeviceCapability(
        is64Bit = true,
        availableMemoryBytes = 8L * 1024 * 1024 * 1024,
        lowMemory = false,
    ),
) : DeviceMemoryProbe {
    override fun capability(): LocalDeviceCapability = capability

    override fun peakMemoryBytes(): Long = 700L * 1024 * 1024
}

private class FakeEngine(
    private val events: List<LocalInferenceEvent> = emptyList(),
) : LocalInferenceEngine {
    private val mutableState = MutableStateFlow<LocalEngineState>(LocalEngineState.Uninitialized)
    override val state: StateFlow<LocalEngineState> = mutableState.asStateFlow()

    var loadCalls = 0
    var loadedPath: String? = null
    var generateCalls = 0
    var lastPrompt: String? = null
    var cancelCalls = 0

    override suspend fun load(model: LocalModel, path: String): LocalLoadResult {
        loadCalls += 1
        loadedPath = path
        mutableState.value = LocalEngineState.Ready(model.id, model.sizeBytes, 500_000_000)
        return LocalLoadResult.Loaded(1200, model.sizeBytes, 500_000_000)
    }

    override fun generate(prompt: String, maxTokens: Int): Flow<LocalInferenceEvent> = flow {
        generateCalls += 1
        lastPrompt = prompt
        events.forEach { emit(it) }
    }

    override fun cancel() {
        cancelCalls += 1
    }

    override suspend fun unload() {
        mutableState.value = LocalEngineState.Uninitialized
    }

    override fun close() = Unit
}

class LocalInferenceViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `verified model is ready and can be loaded`() = runTest(dispatcher) {
        val engine = FakeEngine()
        val viewModel = LocalInferenceViewModel(engine, FakeStore(), FakeDevice())
        advanceUntilIdle()

        val first = viewModel.state.value.models.first()
        assertEquals(ModelPresence.Ready, first.presence)
        assertTrue(first.availability is com.agentroundtable.core.local.LocalAvailability.Available)

        viewModel.loadSelected()
        advanceUntilIdle()

        assertEquals(1, engine.loadCalls)
        assertEquals(LocalModelCatalog.qwen05bQ4Km.fileName, File(engine.loadedPath!!).name)
        assertEquals(LocalModelCatalog.qwen05bQ4Km.id, viewModel.state.value.loadedModelId)
        assertTrue(viewModel.state.value.status!!.contains("模型已加载"))
    }

    @Test
    fun `low memory disables loading with the policy reason`() = runTest(dispatcher) {
        val engine = FakeEngine()
        val device = FakeDevice(
            LocalDeviceCapability(is64Bit = true, availableMemoryBytes = 64L * 1024 * 1024, lowMemory = true),
        )
        val viewModel = LocalInferenceViewModel(engine, FakeStore(), device)
        advanceUntilIdle()

        viewModel.loadSelected()
        advanceUntilIdle()

        assertEquals(0, engine.loadCalls)
        assertTrue(viewModel.state.value.error!!.contains("低内存"))
    }

    @Test
    fun `generation streams tokens and records metrics`() = runTest(dispatcher) {
        val metrics = LocalInferenceMetrics(
            modelLoadMs = 1200,
            firstTokenMs = 320,
            generatedTokens = 11,
            decodeMs = 2000,
            peakMemoryBytes = 700L * 1024 * 1024,
            modelFileBytes = LocalModelCatalog.qwen05bQ4Km.sizeBytes,
        )
        val engine = FakeEngine(
            events = listOf(
                LocalInferenceEvent.Token("你"),
                LocalInferenceEvent.Token("好"),
                LocalInferenceEvent.Completed(metrics),
            ),
        )
        val viewModel = LocalInferenceViewModel(engine, FakeStore(), FakeDevice())
        advanceUntilIdle()
        viewModel.loadSelected()
        advanceUntilIdle()

        viewModel.updatePrompt("打个招呼")
        viewModel.generate()
        advanceUntilIdle()

        val state = viewModel.state.value
        assertEquals("你好", state.output)
        assertEquals(metrics, state.metrics)
        assertEquals(1, engine.generateCalls)
        assertTrue(engine.lastPrompt!!.contains("<|im_start|>user\n打个招呼<|im_end|>"))
        assertTrue(engine.lastPrompt!!.endsWith("<|im_start|>assistant\n"))
        assertEquals(metrics, state.metricsByModel[LocalModelCatalog.qwen05bQ4Km.id])
        assertFalse(state.generationRunning)
        assertTrue(state.canGenerate)
    }

    @Test
    fun `engine failure is reported without throwing`() = runTest(dispatcher) {
        val engine = FakeEngine(events = listOf(LocalInferenceEvent.Failed("模拟失败")))
        val viewModel = LocalInferenceViewModel(engine, FakeStore(), FakeDevice())
        advanceUntilIdle()
        viewModel.loadSelected()
        advanceUntilIdle()

        viewModel.generate()
        advanceUntilIdle()

        assertEquals("模拟失败", viewModel.state.value.error)
        assertFalse(viewModel.state.value.generationRunning)
        assertNotNull(viewModel.state.value.models)
    }
}
