package com.agentroundtable.app.ui.room

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.room.ConnectionState
import com.agentroundtable.core.room.NoticeKind
import com.agentroundtable.core.room.ParticipantView
import com.agentroundtable.core.room.RoomEntry
import com.agentroundtable.core.room.RoomView
import com.agentroundtable.core.room.Stance

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomScreen(
    view: RoomView,
    connection: ConnectionState,
    streaming: String? = null,
    onBack: () -> Unit,
    onDelete: () -> Unit = {},
    deleteError: String? = null,
    onPause: () -> Unit = {},
    onResume: () -> Unit = {},
    onEnd: () -> Unit = {},
    onSendMessage: (String, List<String>) -> Unit = { _, _ -> },
    onRetry: () -> Unit = {},
    controlMessage: String? = null,
    modifier: Modifier = Modifier,
) {
    var confirmDelete by remember { mutableStateOf(false) }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.room_delete)) },
            text = { Text(stringResource(R.string.room_delete_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = { confirmDelete = false; onDelete() },
                    modifier = Modifier.testTag("room.delete.confirm"),
                ) { Text(stringResource(R.string.room_delete_confirm_action)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) {
                    Text(stringResource(R.string.room_delete_cancel))
                }
            },
        )
    }
    val listState = rememberLazyListState()

    // 只有位于底部时才自动跟随新内容，向上翻阅历史时不打断阅读。
    LaunchedEffect(view.entries.size) {
        val last = listState.layoutInfo.totalItemsCount - 1
        if (last >= 0 && listState.firstVisibleItemIndex >= last - 4) {
            listState.animateScrollToItem(view.entries.size)
        }
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = view.topic.ifBlank { stringResource(R.string.home_title) },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.titleMedium,
                        )
                        if (view.maxRounds > 0) {
                            Text(
                                text = stringResource(
                                    R.string.room_round_indicator,
                                    view.currentRound,
                                    view.maxRounds,
                                ),
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                },
                navigationIcon = {
                    TextButton(onClick = onBack, modifier = Modifier.testTag("room.back")) {
                        Text(stringResource(R.string.room_back))
                    }
                },
                actions = {
                    TextButton(
                        onClick = { confirmDelete = true },
                        modifier = Modifier.testTag("room.delete"),
                    ) { Text(stringResource(R.string.room_delete)) }
                },
            )
        },
        bottomBar = {
            RoomControlBar(
                view = view,
                onPause = onPause,
                onResume = onResume,
                onEnd = onEnd,
                onSendMessage = onSendMessage,
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            ParticipantStrip(view.participants)
            ConnectionBanner(connection)
            controlMessage?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            if (view.status == "running" && view.entries.any { it is RoomEntry.Notice && it.kind == NoticeKind.PausePending }) {
                Text(
                    text = stringResource(R.string.room_pause_pending_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            deleteError?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }

            if (view.entries.isEmpty()) {
                Text(
                    text = stringResource(R.string.room_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(24.dp),
                )
            }

            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(view.entries, key = { it.key }) { entry ->
                    when (entry) {
                        is RoomEntry.MessageEntry -> MessageCard(entry)
                        is RoomEntry.Notice -> NoticeRow(entry, onRetry = onRetry)
                    }
                }
                streaming?.takeIf { it.isNotBlank() }?.let { text ->
                    item(key = "streaming") { StreamingCard(text) }
                }
            }
        }
    }
}

@Composable
private fun ParticipantStrip(participants: List<ParticipantView>) {
    if (participants.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        participants.sortedBy { it.position }.forEach { participant ->
            Text(
                text = participant.name,
                style = MaterialTheme.typography.labelLarge,
                color = if (participant.state == "thinking") {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                modifier = Modifier.testTag("room.agent.${participant.key}"),
            )
        }
    }
}

@Composable
private fun ConnectionBanner(connection: ConnectionState) {
    val text = when (connection) {
        ConnectionState.Connecting -> R.string.room_connecting
        ConnectionState.Connected -> R.string.room_connected
        ConnectionState.Reconnecting -> R.string.room_reconnecting
        ConnectionState.Closed -> R.string.room_closed
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .testTag("room.connection"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(text),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MessageCard(entry: RoomEntry.MessageEntry) {
    val message = entry.message
    val stance = Stance.fromWire(message.stance)
    Card(modifier = Modifier.fillMaxWidth().testTag("room.message.${message.id}")) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = message.author.name,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                stance?.let { Text(stanceLabel(it), style = MaterialTheme.typography.labelMedium) }
            }
            message.claim?.takeIf { it.isNotBlank() }?.let {
                Text(text = it, style = MaterialTheme.typography.titleSmall)
            }
            Text(text = message.body, style = MaterialTheme.typography.bodyMedium)
            entry.referenced?.let { quoted ->
                Text(
                    text = stringResource(R.string.room_quoted_from, quoted.author.name, quoted.claim ?: quoted.body),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun RoomControlBar(
    view: RoomView,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onEnd: () -> Unit,
    onSendMessage: (String, List<String>) -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    var mentions by remember { mutableStateOf(emptyList<String>()) }
    var confirmEnd by remember { mutableStateOf(false) }
    val finished = view.status in setOf("completed", "failed", "archived")

    if (confirmEnd) {
        AlertDialog(
            onDismissRequest = { confirmEnd = false },
            title = { Text(stringResource(R.string.room_end)) },
            text = { Text(stringResource(R.string.room_end_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = { confirmEnd = false; onEnd() },
                    modifier = Modifier.testTag("room.end.confirm"),
                ) { Text(stringResource(R.string.room_end)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmEnd = false }) { Text(stringResource(R.string.room_delete_cancel)) }
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (!finished) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (view.status == "paused") {
                    OutlinedButton(
                        onClick = onResume,
                        modifier = Modifier.testTag("room.resume"),
                    ) { Text(stringResource(R.string.room_resume)) }
                } else {
                    OutlinedButton(
                        onClick = onPause,
                        modifier = Modifier.testTag("room.pause"),
                    ) { Text(stringResource(R.string.room_pause)) }
                }
                OutlinedButton(
                    onClick = { confirmEnd = true },
                    modifier = Modifier.testTag("room.end"),
                ) { Text(stringResource(R.string.room_end)) }
            }

            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                view.participants.sortedBy { it.position }.forEach { participant ->
                    FilterChip(
                        selected = participant.id in mentions,
                        onClick = {
                            mentions = if (participant.id in mentions) {
                                mentions - participant.id
                            } else {
                                mentions + participant.id
                            }
                        },
                        label = { Text(participant.name) },
                        modifier = Modifier.testTag("room.mention.${participant.key}"),
                    )
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.weight(1f).testTag("room.composer"),
                    placeholder = { Text(stringResource(R.string.room_message_hint)) },
                    maxLines = 3,
                )
                Button(
                    onClick = {
                        onSendMessage(draft, mentions)
                        draft = ""
                        mentions = emptyList()
                    },
                    enabled = draft.isNotBlank(),
                    modifier = Modifier.testTag("room.send"),
                ) { Text(stringResource(R.string.room_send)) }
            }
        }
    }
}

@Composable
private fun StreamingCard(text: String) {
    Card(
        modifier = Modifier.fillMaxWidth().testTag("room.streaming"),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
        ),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(14.dp),
        )
    }
}

@Composable
private fun NoticeRow(entry: RoomEntry.Notice, onRetry: () -> Unit) {
    val text = when (entry.kind) {
        NoticeKind.RoundStarted -> stringResource(R.string.room_notice_round_started, entry.round)
        NoticeKind.RoundCompleted -> stringResource(R.string.room_notice_round_completed, entry.round)
        NoticeKind.Thinking -> stringResource(R.string.room_notice_thinking, entry.agentName.orEmpty())
        NoticeKind.Typing -> stringResource(R.string.room_notice_typing, entry.agentName.orEmpty())
        NoticeKind.Passed -> stringResource(R.string.room_notice_passed, entry.agentName.orEmpty())
        NoticeKind.Failed -> stringResource(
            if (entry.retryable) R.string.room_notice_failed_retryable else R.string.room_notice_failed,
            entry.agentName.orEmpty(),
            entry.detail.orEmpty(),
        )
        NoticeKind.PausePending -> stringResource(R.string.room_notice_pause_pending)
        NoticeKind.Paused -> stringResource(R.string.room_notice_paused)
        NoticeKind.Resumed -> stringResource(R.string.room_notice_resumed)
        NoticeKind.Ended -> stringResource(R.string.room_notice_ended)
        NoticeKind.BudgetExhausted -> stringResource(R.string.room_notice_budget, entry.detail.orEmpty())
        NoticeKind.SummaryStarted -> stringResource(R.string.room_notice_summary_started)
    }
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
        )
        // 部分输出与完整发言区分展示，避免被误认为已经提交。
        entry.partial?.takeIf { it.isNotBlank() }?.let { partial ->
            Text(
                text = partial,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
            )
        }
        if (entry.kind == NoticeKind.Failed && entry.retryable) {
            TextButton(
                onClick = onRetry,
                modifier = Modifier.testTag("room.retry"),
            ) { Text(stringResource(R.string.home_retry)) }
        }
    }
}

@Composable
private fun stanceLabel(stance: Stance): String = stringResource(
    when (stance) {
        Stance.Support -> R.string.room_stance_support
        Stance.Challenge -> R.string.room_stance_challenge
        Stance.Supplement -> R.string.room_stance_supplement
        Stance.Question -> R.string.room_stance_question
    },
)

@Preview(name = "圆桌", showBackground = true)
@Composable
private fun RoomPreview() {
    AgentRoundtableTheme(dynamicColor = false) {
        RoomScreen(
            view = RoomView(
                topic = "该不该把验证周期压缩到两周？",
                currentRound = 1,
                maxRounds = 2,
                participants = listOf(
                    ParticipantView("p1", 0, "方案派", "advocate", "completed"),
                    ParticipantView("p2", 1, "质疑派", "skeptic", "thinking"),
                ),
                entries = emptyList(),
            ),
            connection = ConnectionState.Connected,
            onBack = {},
        )
    }
}
