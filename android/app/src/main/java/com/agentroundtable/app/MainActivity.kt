package com.agentroundtable.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.agentroundtable.app.data.AppContainer
import com.agentroundtable.app.ui.HomeScreen
import com.agentroundtable.app.ui.create.CreateScreen
import com.agentroundtable.app.ui.create.CreateViewModel
import com.agentroundtable.app.ui.home.HomeViewModel
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = AppContainer(applicationContext)
        setContent {
            AgentRoundtableTheme {
                AgentRoundtableApp(container)
            }
        }
    }
}

@Composable
private fun AgentRoundtableApp(container: AppContainer) {
    var showCreate by rememberSaveable { mutableStateOf(false) }

    if (showCreate) {
        CreateRoute(
            container = container,
            onBack = { showCreate = false },
            onCreated = { showCreate = false },
        )
    } else {
        HomeRoute(container = container, onCreateClicked = { showCreate = true })
    }
}

@Composable
private fun HomeRoute(container: AppContainer, onCreateClicked: () -> Unit) {
    val factory = remember(container) {
        viewModelFactory { initializer { HomeViewModel(container.homeRepository) } }
    }
    val viewModel: HomeViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { viewModel.refresh() }

    HomeScreen(state = state, onCreateClicked = onCreateClicked)
}

@Composable
private fun CreateRoute(
    container: AppContainer,
    onBack: () -> Unit,
    onCreated: (String) -> Unit,
) {
    val factory = remember(container) {
        viewModelFactory {
            initializer {
                CreateViewModel(
                    api = container.apiClient,
                    sessionProvider = { container.guestSessionStore.read() },
                )
            }
        }
    }
    val viewModel: CreateViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(state.createdRoundtableId) {
        val createdId = state.createdRoundtableId ?: return@LaunchedEffect
        viewModel.consumeCreated()
        onCreated(createdId)
    }

    CreateScreen(
        state = state,
        onTopicChange = viewModel::updateTopic,
        onToggleProfile = viewModel::toggleProfile,
        onSubmit = viewModel::submit,
        onBack = onBack,
    )
}
