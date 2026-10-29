package com.agentroundtable.app.ui.create

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.CreateRoundtableRules
import com.agentroundtable.core.model.AgentProfile

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateScreen(
    state: CreateUiState,
    onTopicChange: (String) -> Unit,
    onToggleProfile: (String) -> Unit,
    onSubmit: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.create_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack, modifier = Modifier.testTag("create.back")) {
                        Text(stringResource(R.string.create_back))
                    }
                },
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                OutlinedTextField(
                    value = state.topic,
                    onValueChange = onTopicChange,
                    modifier = Modifier.fillMaxWidth().testTag("create.topic"),
                    label = { Text(stringResource(R.string.create_topic_label)) },
                    placeholder = { Text(stringResource(R.string.create_topic_placeholder)) },
                    supportingText = {
                        Text("${state.topic.trim().length} / ${CreateRoundtableRules.TOPIC_MAX_CHARS}")
                    },
                    isError = state.topic.trim().length > CreateRoundtableRules.TOPIC_MAX_CHARS,
                    minLines = 3,
                    maxLines = 6,
                )
            }

            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = stringResource(R.string.create_agents_label),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = stringResource(
                            R.string.create_selected_count,
                            state.selectedProfileIds.size,
                        ),
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.testTag("create.selectedCount"),
                    )
                }
            }

            items(state.profiles, key = { it.id }) { profile ->
                AgentChoiceCard(
                    profile = profile,
                    selected = profile.id in state.selectedProfileIds,
                    onClick = { onToggleProfile(profile.id) },
                )
            }

            item {
                Text(
                    text = stringResource(R.string.create_mock_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            state.message?.let { message ->
                item {
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("create.message"),
                    )
                }
            }

            item {
                Button(
                    onClick = onSubmit,
                    enabled = !state.isSubmitting && !state.isLoadingProfiles,
                    modifier = Modifier.fillMaxWidth().testTag("create.submit"),
                ) {
                    Text(
                        stringResource(
                            if (state.isSubmitting) R.string.create_submitting else R.string.create_submit,
                        ),
                    )
                }
            }
        }
    }
}

@Composable
private fun AgentChoiceCard(
    profile: AgentProfile,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().testTag("create.agent.${profile.key}"),
        colors = CardDefaults.cardColors(
            containerColor = if (selected) {
                MaterialTheme.colorScheme.secondaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceVariant
            },
        ),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(text = profile.name, style = MaterialTheme.typography.titleMedium)
            Text(
                text = profile.tagline,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = profile.expertise,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Preview(name = "创建圆桌", showBackground = true)
@Composable
private fun CreatePreview() {
    AgentRoundtableTheme(dynamicColor = false) {
        CreateScreen(
            state = CreateUiState(
                topic = "该不该把验证周期压缩到两周？",
                profiles = listOf(
                    AgentProfile(
                        id = "1", key = "advocate", name = "方案派",
                        tagline = "先给出可执行的方案，再谈权衡。",
                        expertise = "方案设计与执行拆解", goal = "提出可落地的方案",
                        defaultStance = "倾向推进", style = "直接、结构化",
                    ),
                ),
                selectedProfileIds = listOf("1"),
                isLoadingProfiles = false,
            ),
            onTopicChange = {}, onToggleProfile = {}, onSubmit = {}, onBack = {},
        )
    }
}
