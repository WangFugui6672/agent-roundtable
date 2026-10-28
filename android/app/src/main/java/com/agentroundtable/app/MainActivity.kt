package com.agentroundtable.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
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
import com.agentroundtable.app.ui.library.LibraryScreen
import com.agentroundtable.app.ui.library.LibraryViewModel
import com.agentroundtable.app.ui.provider.ProviderScreen
import com.agentroundtable.app.ui.provider.ProviderViewModel
import com.agentroundtable.app.ui.room.RoomScreen
import com.agentroundtable.app.ui.room.RoomViewModel
import com.agentroundtable.core.room.RoomController
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.knowledge.DocumentFormat

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

private sealed interface AppRoute {
    data object Home : AppRoute
    data object Create : AppRoute
    data object Provider : AppRoute
    data object Library : AppRoute
    data class Room(val roundtableId: String) : AppRoute
}

@Composable
private fun AgentRoundtableApp(container: AppContainer) {
    var route by rememberSaveable(stateSaver = RouteSaver) {
        mutableStateOf<AppRoute>(AppRoute.Home)
    }

    when (val current = route) {
        AppRoute.Home -> HomeRoute(
            container = container,
            onCreateClicked = { route = AppRoute.Create },
            onOpenRoom = { route = AppRoute.Room(it) },
            onOpenProvider = { route = AppRoute.Provider },
            onOpenLibrary = { route = AppRoute.Library },
        )
        AppRoute.Provider -> ProviderRoute(
            container = container,
            onBack = { route = AppRoute.Home },
        )
        AppRoute.Library -> LibraryRoute(
            container = container,
            onBack = { route = AppRoute.Home },
        )
        AppRoute.Create -> CreateRoute(
            container = container,
            onBack = { route = AppRoute.Home },
            onCreated = { route = AppRoute.Home },
        )
        is AppRoute.Room -> RoomRoute(
            container = container,
            roundtableId = current.roundtableId,
            onBack = { route = AppRoute.Home },
        )
    }
}

private val RouteSaver = listSaver<AppRoute, String>(
    save = { route ->
        when (route) {
            AppRoute.Home -> listOf("home")
            AppRoute.Create -> listOf("create")
            AppRoute.Provider -> listOf("provider")
            AppRoute.Library -> listOf("library")
            is AppRoute.Room -> listOf("room", route.roundtableId)
        }
    },
    restore = { saved ->
        when (saved.first()) {
            "create" -> AppRoute.Create
            "provider" -> AppRoute.Provider
            "library" -> AppRoute.Library
            "room" -> AppRoute.Room(saved.getOrElse(1) { "" })
            else -> AppRoute.Home
        }
    },
)

@Composable
private fun HomeRoute(
    container: AppContainer,
    onCreateClicked: () -> Unit,
    onOpenRoom: (String) -> Unit,
    onOpenProvider: () -> Unit,
    onOpenLibrary: () -> Unit,
) {
    val factory = remember(container) {
        viewModelFactory { initializer { HomeViewModel(container.homeRepository) } }
    }
    val viewModel: HomeViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { viewModel.refresh() }

    HomeScreen(
        state = state,
        onCreateClicked = onCreateClicked,
        onOpenRoom = onOpenRoom,
        onOpenProvider = onOpenProvider,
        onOpenLibrary = onOpenLibrary,
    )
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
                    providerProvider = {
                        val provider = container.providerSettings.load()
                        provider.configuration?.takeIf { provider.isComplete }?.toMetadata()
                    },
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


@Composable
private fun RoomRoute(
    container: AppContainer,
    roundtableId: String,
    onBack: () -> Unit,
) {
    val factory = remember(container, roundtableId) {
        viewModelFactory {
            initializer {
                RoomViewModel(
                    roundtableId = roundtableId,
                    controller = RoomController(
                        factory = container.socketFactory,
                        cache = container.roomCache,
                    ),
                    api = container.apiClient,
                    cache = container.roomCache,
                    sessionProvider = { container.guestSessionStore.read() },
                    turnRunner = container.turnRunner,
                    providerSettings = container.providerSettings,
                    summaryGenerator = container.summaryGenerator,
                )
            }
        }
    }
    val viewModel: RoomViewModel = viewModel(key = roundtableId, factory = factory)
    val view by viewModel.view.collectAsStateWithLifecycle()
    val connection by viewModel.connection.collectAsStateWithLifecycle()
    val deleted by viewModel.deleted.collectAsStateWithLifecycle()
    val deleteError by viewModel.deleteError.collectAsStateWithLifecycle()
    val streaming by viewModel.streaming.collectAsStateWithLifecycle()
    val controlMessage by viewModel.controlMessage.collectAsStateWithLifecycle()
    val summaryGenerating by viewModel.summaryGenerating.collectAsStateWithLifecycle()
    val summaryError by viewModel.summaryError.collectAsStateWithLifecycle()

    LaunchedEffect(deleted) {
        if (deleted) onBack()
    }

    RoomScreen(
        view = view,
        connection = connection,
        streaming = streaming,
        onBack = onBack,
        onDelete = viewModel::delete,
        deleteError = deleteError,
        onPause = viewModel::pause,
        onResume = viewModel::resume,
        onEnd = viewModel::endDiscussion,
        onSendMessage = viewModel::sendUserMessage,
        onRetry = viewModel::retryTurns,
        controlMessage = controlMessage,
        summaryGenerating = summaryGenerating,
        summaryError = summaryError,
        onGenerateSummary = viewModel::startSummaryGenerationIfNeeded,
        onRegenerateSummary = viewModel::regenerateSummary,
    )
}


@Composable
private fun LibraryRoute(container: AppContainer, onBack: () -> Unit) {
    val factory = remember(container) {
        viewModelFactory {
            initializer {
                LibraryViewModel(
                    knowledgeBase = container.knowledgeBase,
                    sourceReader = container.documentSourceReader,
                )
            }
        }
    }
    val viewModel: LibraryViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) viewModel.import(uri.toString())
    }

    LibraryScreen(
        state = state,
        onImportClicked = { picker.launch(DocumentFormat.pickerMimeTypes) },
        onDelete = viewModel::delete,
        onDismissError = viewModel::dismissError,
        onBack = onBack,
    )
}

@Composable
private fun ProviderRoute(container: AppContainer, onBack: () -> Unit) {
    val factory = remember(container) {
        viewModelFactory {
            initializer {
                ProviderViewModel(
                    settings = container.providerSettings,
                    probe = container.providerProbe,
                )
            }
        }
    }
    val viewModel: ProviderViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()

    ProviderScreen(
        state = state,
        onKindSelected = viewModel::selectKind,
        onBaseUrlChange = viewModel::updateBaseUrl,
        onModelChange = viewModel::updateModel,
        onApiKeyChange = viewModel::updateApiKey,
        onSave = viewModel::save,
        onProbe = viewModel::probe,
        onDelete = viewModel::delete,
        onAcknowledgeNotice = viewModel::acknowledgeNotice,
        onBack = onBack,
    )
}
