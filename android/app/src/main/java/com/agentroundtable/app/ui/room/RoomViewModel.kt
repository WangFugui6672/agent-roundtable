package com.agentroundtable.app.ui.room

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.room.ConnectionState
import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.core.room.RoomEntry
import com.agentroundtable.core.room.RoomView
import com.agentroundtable.core.provider.ProviderSettings
import com.agentroundtable.core.summary.RoundSummaryGenerator
import com.agentroundtable.core.summary.SummaryRunResult
import com.agentroundtable.core.turn.TurnRunner
import com.agentroundtable.core.turn.TurnRunResult
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class RoomViewModel(
    private val roundtableId: String,
    private val controller: RoomController,
    private val api: ApiClient,
    private val cache: RoomCache,
    private val sessionProvider: suspend () -> String?,
    private val turnRunner: TurnRunner? = null,
    private val providerSettings: ProviderSettings? = null,
    private val summaryGenerator: RoundSummaryGenerator? = null,
) : ViewModel() {
    val view: StateFlow<RoomView> = controller.view
    val connection: StateFlow<ConnectionState> = controller.connection

    private val _deleted = MutableStateFlow(false)
    val deleted: StateFlow<Boolean> = _deleted.asStateFlow()

    private val _deleteError = MutableStateFlow<String?>(null)
    val deleteError: StateFlow<String?> = _deleteError.asStateFlow()

    /** 正在流式生成中的文本；提交后由 `message.completed` 事件替换为正式发言。 */
    private val _streaming = MutableStateFlow<String?>(null)
    val streaming: StateFlow<String?> = _streaming.asStateFlow()

    /** 控制命令失败时的可展示信息。 */
    private val _controlMessage = MutableStateFlow<String?>(null)
    val controlMessage: StateFlow<String?> = _controlMessage.asStateFlow()

    private val _summaryGenerating = MutableStateFlow(false)
    val summaryGenerating: StateFlow<Boolean> = _summaryGenerating.asStateFlow()

    /** 结论生成或版本冲突的可展示信息。 */
    private val _summaryError = MutableStateFlow<String?>(null)
    val summaryError: StateFlow<String?> = _summaryError.asStateFlow()

    private var sessionId: String? = null
    private var turnsJob: Job? = null
    private var summaryJob: Job? = null
    private var autoSummaryAttempted = false

    init {
        viewModelScope.launch {
            val sessionId = sessionProvider() ?: return@launch
            this@RoomViewModel.sessionId = sessionId
            controller.connect(
                scope = viewModelScope,
                roundtableId = roundtableId,
                sessionId = sessionId,
            )
            startTurns()
        }
        // 讨论自然结束或用户提前结束后，自动生成一次结论；失败后不无限重试，由用户手动触发。
        viewModelScope.launch {
            view.collect { current ->
                if (current.hasSnapshot &&
                    current.status == SUMMARY_READY_STATUS &&
                    current.summary == null &&
                    !autoSummaryAttempted
                ) {
                    autoSummaryAttempted = true
                    launchSummaryGeneration(regenerate = false)
                }
            }
        }
    }

    /** 失败后重试：重新启动 Turn 循环，沿用服务端已签发的下一个 Turn。 */
    fun retryTurns() {
        _controlMessage.value = null
        startTurns()
    }

    fun pause() = control { api.pauseRoundtable(it, roundtableId) }

    fun resume() {
        control { api.resumeRoundtable(it, roundtableId) }
        startTurns()
    }

    /** 提前结束：服务端取消在途 Turn，本地同时停止生成。 */
    fun endDiscussion() {
        turnsJob?.cancel()
        turnsJob = null
        _streaming.value = null
        control { api.endRoundtable(it, roundtableId) }
    }

    fun sendUserMessage(body: String, mentionedAgentIds: List<String>) {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            val session = sessionId ?: return@launch
            when (val result = api.sendUserMessage(session, roundtableId, trimmed, mentionedAgentIds)) {
                is ApiResult.Failure -> _controlMessage.value = result.message
                is ApiResult.Success -> controller.applyEvents(result.value.events)
            }
        }
    }

    fun consumeControlMessage() {
        _controlMessage.value = null
    }

    /** 手动生成结论：仅在总结态且尚未保存结论时可用。 */
    fun startSummaryGenerationIfNeeded() {
        val current = view.value
        if (current.status != SUMMARY_READY_STATUS || current.summary != null) return
        launchSummaryGeneration(regenerate = false)
    }

    /** 重新生成：携带当前版本，版本过期时服务端返回冲突而不是静默覆盖。 */
    fun regenerateSummary() {
        if (view.value.summary == null) return
        launchSummaryGeneration(regenerate = true)
    }

    private fun launchSummaryGeneration(regenerate: Boolean) {
        if (summaryJob?.isActive == true || _summaryGenerating.value) return
        val generator = summaryGenerator ?: return
        val snapshot = view.value
        if (regenerate && snapshot.summary == null) return
        if (!regenerate && (snapshot.status != SUMMARY_READY_STATUS || snapshot.summary != null)) return

        val expectedVersion = snapshot.summary?.version ?: 0
        _summaryGenerating.value = true
        _summaryError.value = null
        summaryJob = viewModelScope.launch {
            try {
                val session = sessionProvider()
                if (session == null) {
                    _summaryError.value = "还没有可用的匿名会话。"
                    return@launch
                }
                val providerState = providerSettings?.load()
                val configuration = providerState?.configuration?.takeIf { providerState.isComplete }
                val apiKey = if (configuration != null) providerSettings.apiKey() else null
                val transcript = snapshot.entries
                    .filterIsInstance<RoomEntry.MessageEntry>()
                    .map { it.message }

                when (
                    val result = generator.generateAndSubmit(
                        sessionId = session,
                        roundtableId = roundtableId,
                        topic = snapshot.topic,
                        transcript = transcript,
                        expectedVersion = expectedVersion,
                        configuration = configuration,
                        apiKey = apiKey,
                    )
                ) {
                    is SummaryRunResult.Saved -> controller.applySummaryResponse(result.response)
                    is SummaryRunResult.Conflict -> _summaryError.value = result.message
                    is SummaryRunResult.Failed -> _summaryError.value = result.message
                }
            } finally {
                _summaryGenerating.value = false
                summaryJob = null
            }
        }
    }

    private fun control(action: suspend (String) -> ApiResult<com.agentroundtable.core.turn.ControlResponse>) {
        viewModelScope.launch {
            val session = sessionId ?: return@launch
            when (val result = action(session)) {
                is ApiResult.Failure -> _controlMessage.value = result.message
                is ApiResult.Success -> controller.applyEvents(result.value.events)
            }
        }
    }

    private fun startTurns() {
        if (turnsJob?.isActive == true) return
        val session = sessionId ?: return
        turnsJob = viewModelScope.launch { runTurns(session) }
    }

    /**
     * 只要圆桌使用真实 Provider 就持续申请并执行 Turn。
     *
     * Mock 圆桌由服务端脚本驱动，客户端不参与生成。
     */
    private suspend fun runTurns(sessionId: String) {
        val runner = turnRunner ?: return
        val settings = providerSettings ?: return
        val state = settings.load()
        val configuration = state.configuration ?: return
        if (!state.isComplete) return
        val apiKey = settings.apiKey() ?: return

        // 等 `room.joined` 到达：缓存恢复的视图没有参与者上下文，装不出 prompt。
        withTimeoutOrNull(READY_TIMEOUT_MS) {
            controller.view.first { it.hasSnapshot && it.participants.isNotEmpty() }
        } ?: return

        repeat(MAX_TURNS_PER_VISIT) {
            val current = controller.view.value
            if (current.isMock) return
            if (current.status in TERMINAL_STATUSES) return
            // 暂停期间不签发新 Turn；继续时由 resume 重新启动本循环。
            if (current.status == "paused") return
            if (controller.connection.value == ConnectionState.Closed) return

            val transcript = current.entries
                .filterIsInstance<com.agentroundtable.core.room.RoomEntry.MessageEntry>()
                .map {
                    com.agentroundtable.core.turn.TranscriptLine(
                        authorName = it.message.author.name,
                        body = it.message.body,
                        messageId = it.message.id,
                        authorAgentId = it.message.author.roundtableAgentId,
                    )
                }

            val result = runner.runOnce(
                sessionId = sessionId,
                roundtableId = roundtableId,
                configuration = configuration,
                apiKey = apiKey,
                transcript = transcript,
                contextFor = { agentId ->
                    current.participants.firstOrNull { it.id == agentId }?.let { participant ->
                        com.agentroundtable.core.turn.PromptContext(
                            topic = current.topic,
                            agentName = participant.name,
                            tagline = participant.tagline,
                            expertise = participant.expertise,
                            goal = participant.goal,
                            defaultStance = participant.defaultStance,
                            style = participant.style,
                            bannedBehaviors = participant.bannedBehaviors,
                            maxReplyChars = participant.maxReplyChars,
                            roundNumber = current.currentRound,
                        )
                    }
                },
                onDelta = { delta ->
                    _streaming.value = (_streaming.value ?: "") + delta
                },
            )
            _streaming.value = null

            when (result) {
                TurnRunResult.NoTurn, is TurnRunResult.Failed -> return
                is TurnRunResult.Spoke, TurnRunResult.Passed -> Unit
            }
        }
    }

    private companion object {
        const val MAX_TURNS_PER_VISIT = 12
        const val READY_TIMEOUT_MS = 20_000L
        const val SUMMARY_READY_STATUS = "summarizing"
        val TERMINAL_STATUSES = setOf("summarizing", "completed", "failed", "archived")
    }

    /**
     * 提前结束并删除圆桌。先写墓碑再删除缓存，保证即使后续清理失败，
     * 恢复路径也不会把已删除内容再显示出来。
     */
    fun delete() {
        viewModelScope.launch {
            val sessionId = sessionProvider()
            if (sessionId == null) {
                _deleteError.value = "还没有可用的匿名会话。"
                return@launch
            }
            when (val result = api.deleteRoundtable(sessionId, roundtableId)) {
                is ApiResult.Failure -> _deleteError.value = result.message
                is ApiResult.Success -> {
                    controller.disconnect()
                    cache.delete(roundtableId)
                    _deleted.value = true
                }
            }
        }
    }

    override fun onCleared() {
        summaryJob?.cancel()
        summaryJob = null
        controller.disconnect()
        super.onCleared()
    }
}
