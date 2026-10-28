package com.agentroundtable.app.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.agentroundtable.app.R
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.knowledge.DocumentFormat
import com.agentroundtable.core.knowledge.KnowledgeDocument

/**
 * 资料库：本机文档列表、导入入口、处理进度与错误。
 *
 * 所有内容只在本机处理，界面不提供任何上传或同步入口。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    state: LibraryUiState,
    onImportClicked: () -> Unit,
    onDelete: (String) -> Unit,
    onDismissError: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pendingDelete by remember { mutableStateOf<KnowledgeDocument?>(null) }

    pendingDelete?.let { document ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.library_delete_dialog_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.library_delete_dialog_body,
                        document.name,
                        document.chunkCount,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDelete = null
                        onDelete(document.id)
                    },
                    modifier = Modifier.testTag("library.delete.confirm"),
                ) { Text(stringResource(R.string.library_delete_confirm)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { pendingDelete = null },
                    modifier = Modifier.testTag("library.delete.cancel"),
                ) { Text(stringResource(R.string.library_delete_cancel)) }
            },
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.library_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack, modifier = Modifier.testTag("library.back")) {
                        Text(stringResource(R.string.library_back))
                    }
                },
                actions = {
                    TextButton(
                        onClick = onImportClicked,
                        enabled = !state.isImporting,
                        modifier = Modifier.testTag("library.import"),
                    ) { Text(stringResource(R.string.library_import)) }
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
            contentPadding = PaddingValues(vertical = 16.dp),
        ) {
            item {
                LibraryNotice()
            }

            if (state.isImporting) {
                item {
                    ImportingRow()
                }
            }

            state.errorMessage?.let { message ->
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("library.error"),
                        )
                        TextButton(
                            onClick = onDismissError,
                            modifier = Modifier.testTag("library.dismissError"),
                        ) { Text(stringResource(R.string.library_error_dismiss)) }
                    }
                }
            }

            if (state.isLoading && state.documents.isEmpty()) {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator()
                    }
                }
            } else if (state.documents.isEmpty()) {
                item {
                    EmptyLibrary()
                }
            } else {
                items(state.documents, key = { it.id }) { document ->
                    DocumentCard(
                        document = document,
                        onDelete = { pendingDelete = document },
                    )
                }
            }
        }
    }
}

@Composable
private fun LibraryNotice() {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = stringResource(R.string.library_local_notice),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = stringResource(R.string.library_formats),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = stringResource(R.string.library_docx_notice),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag("library.docxNotice"),
        )
    }
}

@Composable
private fun ImportingRow() {
    Row(
        modifier = Modifier.fillMaxWidth().testTag("library.importing"),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(32.dp))
        Text(
            text = stringResource(R.string.library_import_progress),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun EmptyLibrary() {
    Column(
        modifier = Modifier.testTag("library.empty"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(R.string.library_empty_title),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = stringResource(R.string.library_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun DocumentCard(document: KnowledgeDocument, onDelete: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().testTag("library.document.${document.id}")) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = document.name,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = stringResource(
                        R.string.library_document_meta,
                        document.format.displayName,
                        document.chunkCount,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("library.chunks.${document.id}"),
                )
            }
            TextButton(
                onClick = onDelete,
                modifier = Modifier.testTag("library.delete.${document.id}"),
            ) { Text(stringResource(R.string.library_delete)) }
        }
    }
}

@Preview(name = "资料库", showBackground = true)
@Composable
private fun LibraryPreview() {
    AgentRoundtableTheme(dynamicColor = false) {
        LibraryScreen(
            state = LibraryUiState(
                isLoading = false,
                documents = listOf(
                    KnowledgeDocument(
                        id = "1",
                        name = "竞品调研.pdf",
                        format = DocumentFormat.Pdf,
                        chunkCount = 18,
                        importedAt = 0L,
                    ),
                    KnowledgeDocument(
                        id = "2",
                        name = "会议记录.md",
                        format = DocumentFormat.Markdown,
                        chunkCount = 6,
                        importedAt = 0L,
                    ),
                ),
            ),
            onImportClicked = {},
            onDelete = {},
            onDismissError = {},
            onBack = {},
        )
    }
}
