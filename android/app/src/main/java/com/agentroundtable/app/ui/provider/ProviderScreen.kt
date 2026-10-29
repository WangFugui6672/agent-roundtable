package com.agentroundtable.app.ui.provider

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.core.provider.ProviderCheckOutcome
import com.agentroundtable.core.provider.ProviderKind

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderScreen(
    state: ProviderUiState,
    onKindSelected: (ProviderKind) -> Unit,
    onBaseUrlChange: (String) -> Unit,
    onModelChange: (String) -> Unit,
    onApiKeyChange: (String) -> Unit,
    onSave: () -> Unit,
    onProbe: () -> Unit,
    onDelete: () -> Unit,
    onAcknowledgeNotice: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!state.noticeAcknowledged) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text(stringResource(R.string.provider_notice_title)) },
            text = { Text(stringResource(R.string.provider_notice_body)) },
            confirmButton = {
                TextButton(
                    onClick = onAcknowledgeNotice,
                    modifier = Modifier.testTag("provider.notice.accept"),
                ) { Text(stringResource(R.string.provider_notice_accept)) }
            },
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.provider_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack, modifier = Modifier.testTag("provider.back")) {
                        Text(stringResource(R.string.provider_back))
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
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(stringResource(R.string.provider_kind), style = MaterialTheme.typography.titleSmall)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ProviderKind.entries.forEach { kind ->
                        FilterChip(
                            selected = state.kind == kind,
                            onClick = { onKindSelected(kind) },
                            label = { Text(kind.displayName) },
                            modifier = Modifier.testTag("provider.kind.${kind.wireValue}"),
                        )
                    }
                }
            }

            item {
                OutlinedTextField(
                    value = state.baseUrl,
                    onValueChange = onBaseUrlChange,
                    label = { Text(stringResource(R.string.provider_base_url)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("provider.baseUrl"),
                )
            }

            item {
                OutlinedTextField(
                    value = state.model,
                    onValueChange = onModelChange,
                    label = { Text(stringResource(R.string.provider_model)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("provider.model"),
                )
            }

            item {
                OutlinedTextField(
                    value = state.apiKey,
                    onValueChange = onApiKeyChange,
                    label = { Text(stringResource(R.string.provider_api_key)) },
                    placeholder = {
                        Text(
                            stringResource(
                                if (state.hasStoredKey) {
                                    R.string.provider_api_key_saved
                                } else {
                                    R.string.provider_api_key_hint
                                },
                            ),
                        )
                    },
                    singleLine = true,
                    // 不设置 textContentType(password)，避免进入系统密码 AutoFill。
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth().testTag("provider.apiKey"),
                )
            }

            if (!state.saved.isComplete) {
                item {
                    Text(
                        text = stringResource(R.string.provider_incomplete),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag("provider.incomplete"),
                    )
                }
            }

            state.probeOutcome?.let { outcome ->
                item {
                    Text(
                        text = probeMessage(outcome),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.testTag("provider.probeResult"),
                    )
                }
            }

            state.message?.let { message ->
                item {
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.testTag("provider.message"),
                    )
                }
            }

            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = onSave,
                        enabled = !state.isBusy,
                        modifier = Modifier.fillMaxWidth().testTag("provider.save"),
                    ) { Text(stringResource(R.string.provider_save)) }

                    OutlinedButton(
                        onClick = onProbe,
                        enabled = !state.isBusy,
                        modifier = Modifier.fillMaxWidth().testTag("provider.probe"),
                    ) { Text(stringResource(R.string.provider_probe)) }

                    TextButton(
                        onClick = onDelete,
                        modifier = Modifier.fillMaxWidth().testTag("provider.delete"),
                    ) { Text(stringResource(R.string.provider_delete)) }
                }
            }
        }
    }
}

@Composable
private fun probeMessage(outcome: ProviderCheckOutcome): String = when (outcome) {
    is ProviderCheckOutcome.Ok -> outcome.modelCount?.let {
        stringResource(R.string.provider_probe_ok_count, it)
    } ?: stringResource(R.string.provider_probe_ok)
    ProviderCheckOutcome.InvalidKey -> stringResource(R.string.provider_probe_invalid_key)
    is ProviderCheckOutcome.ModelMissing ->
        stringResource(R.string.provider_probe_model_missing, outcome.model)
    is ProviderCheckOutcome.Unreachable ->
        stringResource(R.string.provider_probe_unreachable, outcome.reason)
    is ProviderCheckOutcome.Failed -> outcome.reason
}
