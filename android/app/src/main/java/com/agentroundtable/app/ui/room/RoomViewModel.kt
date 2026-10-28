package com.agentroundtable.app.ui.room

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.room.ConnectionState
import com.agentroundtable.core.room.RoomCache
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.core.room.RoomView
import com.agentroundtable.core.provider.ProviderSettings
import com.agentroundtable.core.turn.TurnRunner
import com.agentroundtable.core.turn.TurnRunResult
import kotlinx.coroutines.flow.MutableStateFlow
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

    init {
        viewModelScope.launch {
            val sessionId = sessionProvider() ?: return@launch
            controller.connect(
                scope = viewModelScope,
                roundtableId = roundtableId,
                sessionId = sessionId,
            )
            runTurns(sessionId)
        }
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
        val TERMINAL_STATUSES = setOf("completed", "failed", "archived")
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
        controller.disconnect()
        super.onCleared()
    }
}
