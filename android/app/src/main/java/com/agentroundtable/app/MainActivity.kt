package com.agentroundtable.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.agentroundtable.app.ui.HomeScreen
import com.agentroundtable.app.ui.theme.AgentRoundtableTheme
import com.agentroundtable.core.HomeState

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AgentRoundtableTheme {
                HomeScreen(state = HomeState.Empty)
            }
        }
    }
}
