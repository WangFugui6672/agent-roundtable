package com.agentroundtable.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.HomeState

/**
 * 首页。当前只渲染空态；有内容态在后续切片中补齐。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: HomeState,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier.semantics { contentDescription = "home.screen" },
        topBar = { TopAppBar(title = { Text(stringResource(R.string.home_title)) }) },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            when (state) {
                HomeState.Empty -> EmptyHome()
            }
        }
    }
}

@Composable
private fun EmptyHome() {
    Text(
        text = stringResource(R.string.home_empty_title),
        style = MaterialTheme.typography.headlineSmall,
    )
    Text(
        text = stringResource(R.string.home_empty_body),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Button(onClick = { /* 创建圆桌在后续切片接入 */ }) {
        Text(stringResource(R.string.home_create))
    }
}

@Preview(name = "空态 · 浅色", showBackground = true)
@Composable
private fun EmptyHomeLightPreview() {
    AgentRoundtableTheme(darkTheme = false) { HomeScreen(state = HomeState.Empty) }
}

@Preview(name = "空态 · 深色", showBackground = true, backgroundColor = 0xFF101416)
@Composable
private fun EmptyHomeDarkPreview() {
    AgentRoundtableTheme(darkTheme = true) { HomeScreen(state = HomeState.Empty) }
}
