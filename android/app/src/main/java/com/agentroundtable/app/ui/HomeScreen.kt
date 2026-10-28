package com.agentroundtable.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.HomeState
import com.agentroundtable.core.model.RoundtableCard
import com.agentroundtable.core.model.RoundtableStatus

/**
 * 首页：加载中、空态、列表与失败四种状态。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: HomeState,
    onCreateClicked: () -> Unit,
    onOpenRoom: (String) -> Unit = {},
    onOpenProvider: () -> Unit = {},
    onOpenLocal: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.home_title)) },
                actions = {
                    TextButton(
                        onClick = onOpenLocal,
                        modifier = Modifier.testTag("home.local"),
                    ) { Text(stringResource(R.string.home_local)) }
                    TextButton(
                        onClick = onOpenProvider,
                        modifier = Modifier.testTag("home.provider"),
                    ) { Text(stringResource(R.string.home_provider)) }
                },
            )
        },
        floatingActionButton = {
            if (state !is HomeState.Empty) {
                Button(onClick = onCreateClicked, modifier = Modifier.testTag("home.create")) {
                    Text(stringResource(R.string.home_create))
                }
            }
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .windowInsetsPadding(WindowInsets.safeDrawing),
            contentAlignment = Alignment.Center,
        ) {
            when (state) {
                HomeState.Loading -> LoadingHome()
                HomeState.Empty -> EmptyHome(onCreateClicked)
                is HomeState.Rooms -> RoomList(state.items, onOpenRoom)
                is HomeState.Failed -> FailedHome(state.message)
            }
        }
    }
}

@Composable
private fun LoadingHome() {
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
        Text(stringResource(R.string.home_loading), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun EmptyHome(onCreateClicked: () -> Unit) {
    Column(
        modifier = Modifier.padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(R.string.home_empty_title),
            style = MaterialTheme.typography.headlineSmall,
        )
        Text(
            text = stringResource(R.string.home_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onCreateClicked, modifier = Modifier.testTag("home.create")) {
            Text(stringResource(R.string.home_create))
        }
    }
}

@Composable
private fun FailedHome(message: String) {
    Column(
        modifier = Modifier.padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = message, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun RoomList(items: List<RoundtableCard>, onOpenRoom: (String) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 16.dp, 16.dp, 96.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(items, key = { it.id }) { card ->
            RoomCard(card, onOpenRoom)
        }
    }
}

@Composable
private fun RoomCard(card: RoundtableCard, onOpenRoom: (String) -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onOpenRoom(card.id) }
            .testTag("home.room.${card.id}"),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = card.topic,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = statusLabel(card.status),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun statusLabel(status: RoundtableStatus): String = stringResource(
    when (status) {
        RoundtableStatus.Draft -> R.string.status_draft
        RoundtableStatus.Ready -> R.string.status_ready
        RoundtableStatus.Running -> R.string.status_running
        RoundtableStatus.Paused -> R.string.status_paused
        RoundtableStatus.Summarizing -> R.string.status_summarizing
        RoundtableStatus.Completed -> R.string.status_completed
        RoundtableStatus.Failed -> R.string.status_failed
        RoundtableStatus.Archived -> R.string.status_archived
        RoundtableStatus.Unknown -> R.string.status_unknown
    },
)

@Preview(name = "空态", showBackground = true)
@Composable
private fun EmptyPreview() {
    AgentRoundtableTheme(dynamicColor = false) { HomeScreen(HomeState.Empty, onCreateClicked = {}) }
}

@Preview(name = "列表", showBackground = true)
@Composable
private fun ListPreview() {
    AgentRoundtableTheme(dynamicColor = false) {
        HomeScreen(
            HomeState.Rooms(
                listOf(
                    RoundtableCard("1", "该不该把验证周期压缩到两周？", RoundtableStatus.Running),
                    RoundtableCard("2", "预算有限时先做体验还是先做功能？", RoundtableStatus.Completed),
                ),
            ),
            onCreateClicked = {},
        )
    }
}
