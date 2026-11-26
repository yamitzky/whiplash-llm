package com.yamitzky.whiplash.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import android.os.Build

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            WhiplashTheme {
                ChatScreen(viewModel())
            }
        }
    }
}

@Composable
private fun WhiplashTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatScreen(viewModel: ChatViewModel) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    // 初回は接続先が無く送れないので、先に設定を開く。
    LaunchedEffect(Unit) { if (!viewModel.isConfigured) showSettings = true }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Whiplash") },
                actions = { TextButton(onClick = { showSettings = true }) { Text("接続先") } },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.padding(padding).padding(16.dp).fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = viewModel.input,
                onValueChange = { viewModel.input = it },
                label = { Text("テキスト") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                maxLines = 6,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (viewModel.isGenerating) {
                    Button(onClick = viewModel::stop) { Text("停止") }
                } else {
                    Button(
                        onClick = {
                            if (viewModel.isConfigured) {
                                // キーボードが返答の欄を隠すので、送ったら閉じる。
                                keyboard?.hide()
                                viewModel.send()
                            } else {
                                showSettings = true
                            }
                        },
                        enabled = viewModel.input.isNotBlank(),
                    ) { Text("送信") }
                }
            }
            ResponseCard(viewModel.output, viewModel.error, Modifier.fillMaxWidth().weight(1f))
        }
    }

    if (showSettings) {
        ConnectionDialog(
            initial = remember { viewModel.connectionForm() },
            onDismiss = { showSettings = false },
            onSave = {
                viewModel.saveConnection(it)
                showSettings = false
            },
        )
    }
}

@Composable
private fun ResponseCard(text: String, error: String?, modifier: Modifier) {
    val (thinking, body) = splitThinking(text)
    Card(modifier = modifier) {
        Column(
            modifier = Modifier.padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (thinking != null) {
                Text(thinking, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (body.isNotEmpty()) {
                Text(body, style = MaterialTheme.typography.bodyLarge)
            } else if (error == null && thinking == null) {
                Text("返答はここに表示されます", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (error != null) {
                Text(error, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/**
 * 共有コアの `Prompt.displayText` は thinking を `<thinking>…</thinking>\n\n本文` の形で前に付ける。
 * macOS の StreamingText と iOS の StreamingResult と同じく、このタグで分けて表示する。
 * 閉じタグが届く前は、全部を thinking として扱う。
 */
internal fun splitThinking(text: String): Pair<String?, String> {
    if (!text.startsWith(THINKING_OPEN)) return null to text
    val end = text.indexOf(THINKING_CLOSE)
    if (end < 0) return text.removePrefix(THINKING_OPEN) to ""
    val thinking = text.substring(THINKING_OPEN.length, end)
    val body = text.substring(end + THINKING_CLOSE.length).removePrefix("\n\n")
    return thinking to body
}

private const val THINKING_OPEN = "<thinking>"
private const val THINKING_CLOSE = "</thinking>"

@Composable
private fun ConnectionDialog(initial: ConnectionForm, onDismiss: () -> Unit, onSave: (ConnectionForm) -> Unit) {
    var endpoint by rememberSaveable { mutableStateOf(initial.endpoint) }
    var modelIdentifier by rememberSaveable { mutableStateOf(initial.modelIdentifier) }
    var apiKey by rememberSaveable { mutableStateOf(initial.apiKey) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("接続先") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("OpenAI 互換の Chat Completions API に送ります。", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = endpoint,
                    onValueChange = { endpoint = it },
                    label = { Text("URL") },
                    placeholder = { Text("http://localhost:1234/v1") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                )
                OutlinedTextField(
                    value = modelIdentifier,
                    onValueChange = { modelIdentifier = it },
                    label = { Text("モデル ID") },
                    singleLine = true,
                    // モデル ID は "openai/gpt-4o" や "llama3.2:3b" のような英数字と記号なので、URL 用のキーボードを出す。
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                )
                OutlinedTextField(
                    value = apiKey,
                    onValueChange = { apiKey = it },
                    label = { Text("API キー (任意)") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(ConnectionForm(endpoint, modelIdentifier, apiKey)) },
                enabled = endpoint.isNotBlank() && modelIdentifier.isNotBlank(),
            ) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("キャンセル") } },
    )
}
