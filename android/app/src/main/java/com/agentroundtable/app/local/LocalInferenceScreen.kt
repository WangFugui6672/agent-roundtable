package com.agentroundtable.app.local

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.core.local.LocalAvailability
import com.agentroundtable.core.local.LocalInferenceMetrics
import com.agentroundtable.core.local.LocalInferencePolicy

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocalInferenceScreen(
    state: LocalInferenceUiState,
    onBack: () -> Unit,
    onSelect: (String) -> Unit,
    onDownload: (String) -> Unit,
    onImport: (android.net.Uri) -> Unit,
    onLoad: () -> Unit,
    onGenerate: () -> Unit,
    onStop: () -> Unit,
    onUnload: () -> Unit,
    onPromptChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) onImport(uri)
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.local_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack, modifier = Modifier.testTag("local.back")) {
                        Text(stringResource(R.string.local_back))
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp, 16.dp, 16.dp, 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(
                    text = stringResource(R.string.local_intro),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            val selected = state.selectedModel
            if (selected != null && selected.availability is LocalAvailability.Disabled) {
                item {
                    DisabledBanner(selected.availability.reason)
                }
            }
            item {
                Text(stringResource(R.string.local_model_section), style = MaterialTheme.typography.titleMedium)
            }
            items(state.models, key = { it.model.id }) { ui ->
                ModelCard(
                    ui = ui,
                    selected = ui.model.id == state.selectedModelId,
                    busy = state.busy,
                    loaded = state.loadedModelId == ui.model.id,
                    onSelect = { onSelect(ui.model.id) },
                    onDownload = { onDownload(ui.model.id) },
                    onLoad = onLoad,
                )
            }
            item {
                OutlinedButton(
                    onClick = { picker.launch(arrayOf("*/*")) },
                    enabled = !state.busy,
                    modifier = Modifier.testTag("local.import"),
                ) {
                    Text(stringResource(R.string.local_import))
                }
            }
            item {
                OutlinedTextField(
                    value = state.prompt,
                    onValueChange = onPromptChange,
                    label = { Text(stringResource(R.string.local_prompt)) },
                    enabled = !state.generationRunning,
                    minLines = 2,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("local.prompt"),
                )
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = onGenerate,
                        enabled = state.canGenerate,
                        modifier = Modifier.testTag("local.generate"),
                    ) {
                        Text(stringResource(R.string.local_generate))
                    }
                    OutlinedButton(
                        onClick = onStop,
                        enabled = state.generationRunning,
                        modifier = Modifier.testTag("local.stop"),
                    ) {
                        Text(stringResource(R.string.local_stop))
                    }
                    OutlinedButton(
                        onClick = onUnload,
                        enabled = !state.generationRunning && state.loadedModelId != null,
                        modifier = Modifier.testTag("local.unload"),
                    ) {
                        Text(stringResource(R.string.local_unload))
                    }
                }
            }
            state.status?.let { status ->
                item {
                    Text(
                        text = status,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.testTag("local.status"),
                    )
                }
            }
            state.error?.let { error ->
                item {
                    Text(
                        text = error,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("local.error"),
                    )
                }
            }
            item {
                Text(stringResource(R.string.local_output), style = MaterialTheme.typography.titleMedium)
            }
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = state.output.ifEmpty { stringResource(R.string.local_output_empty) },
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier
                            .padding(16.dp)
                            .testTag("local.output"),
                    )
                }
            }
            state.metrics?.let { metrics ->
                item { MetricsCard(metrics) }
            }
            item { QuantizationCard(state) }
            item {
                Text(
                    text = stringResource(R.string.local_footer),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun DisabledBanner(reason: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.local_unavailable), style = MaterialTheme.typography.titleSmall)
            Text(reason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun ModelCard(
    ui: LocalModelUi,
    selected: Boolean,
    busy: Boolean,
    loaded: Boolean,
    onSelect: () -> Unit,
    onDownload: () -> Unit,
    onLoad: () -> Unit,
) {
    val available = ui.availability is LocalAvailability.Available
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(selected = selected, enabled = !busy, onClick = onSelect)
            .testTag("local.model.${ui.model.id}"),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = selected, onClick = onSelect, enabled = !busy)
                Column(modifier = Modifier.weight(1f)) {
                    Text(ui.model.displayName, style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = "${ui.model.quantization} · ${LocalInferencePolicy.formatMiB(ui.model.sizeBytes)} · ${ui.model.parameterLabel}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Text(
                text = if (loaded) "已加载" else presenceLabel(ui.presence),
                style = MaterialTheme.typography.bodySmall,
                color = when {
                    ui.presence is ModelPresence.Failed -> MaterialTheme.colorScheme.error
                    ui.presence == ModelPresence.Ready -> MaterialTheme.colorScheme.primary
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
            if (ui.presence is ModelPresence.Downloading) {
                LinearProgressIndicator(
                    progress = { ui.presence.progress },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (!available) {
                Text(
                    text = (ui.availability as LocalAvailability.Disabled).reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = onDownload,
                    enabled = available && !busy && ui.presence !is ModelPresence.Ready &&
                        ui.presence !is ModelPresence.Downloading,
                    modifier = Modifier.testTag("local.download.${ui.model.id}"),
                ) {
                    Text(stringResource(R.string.local_download))
                }
                Button(
                    onClick = onLoad,
                    enabled = available && !busy && ui.presence == ModelPresence.Ready && !loaded,
                    modifier = Modifier.testTag("local.load.${ui.model.id}"),
                ) {
                    Text(stringResource(R.string.local_load))
                }
            }
        }
    }
}

@Composable
private fun presenceLabel(presence: ModelPresence): String = when (presence) {
    ModelPresence.NotDownloaded -> stringResource(R.string.local_presence_missing)
    is ModelPresence.Downloading -> stringResource(
        R.string.local_status_downloading,
        (presence.progress * 100).toInt(),
    )
    ModelPresence.Verifying -> stringResource(R.string.local_presence_verifying)
    ModelPresence.Ready -> stringResource(R.string.local_presence_ready)
    is ModelPresence.Failed -> presence.message
}

@Composable
private fun MetricsCard(metrics: LocalInferenceMetrics) {
    Card(modifier = Modifier.fillMaxWidth().testTag("local.metrics")) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.local_metrics), style = MaterialTheme.typography.titleMedium)
            MetricRow(stringResource(R.string.local_metric_load), "${metrics.modelLoadMs} ms")
            MetricRow(stringResource(R.string.local_metric_ttft), "${metrics.firstTokenMs} ms")
            MetricRow(
                stringResource(R.string.local_metric_decode),
                String.format("%.2f tokens/s", metrics.tokensPerSecond),
            )
            MetricRow(
                stringResource(R.string.local_metric_size),
                LocalInferencePolicy.formatMiB(metrics.modelFileBytes),
            )
            MetricRow(
                stringResource(R.string.local_metric_memory),
                LocalInferencePolicy.formatMiB(metrics.peakMemoryBytes),
            )
            Text(
                text = stringResource(R.string.local_metric_definition),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun MetricRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun QuantizationCard(state: LocalInferenceUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.local_quant_section), style = MaterialTheme.typography.titleMedium)
            state.models.forEach { ui ->
                val metrics = state.metricsByModel[ui.model.id]
                MetricRow(
                    "${ui.model.quantization} · ${LocalInferencePolicy.formatMiB(ui.model.sizeBytes)}",
                    metrics?.let { String.format("%.2f tokens/s", it.tokensPerSecond) }
                        ?: stringResource(R.string.local_quant_unverified),
                )
            }
            Text(
                text = stringResource(R.string.local_quant_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
