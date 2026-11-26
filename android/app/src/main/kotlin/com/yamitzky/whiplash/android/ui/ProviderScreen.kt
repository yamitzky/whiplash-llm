package com.yamitzky.whiplash.android.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.yamitzky.whiplash.android.AppContainer
import com.yamitzky.whiplash.android.NanoStatus
import com.yamitzky.whiplash.android.label
import com.yamitzky.whiplash.shared.model.BackendProvider
import kotlinx.coroutines.launch

@Composable
fun ProviderScreen(container: AppContainer, provider: BackendProvider, onDone: () -> Unit) {
    if (provider == BackendProvider.FoundationModels) {
        GeminiNanoScreen(container, onDone)
        return
    }
    val settings = container.settings
    var apiKey by rememberSaveable { mutableStateOf(settings.apiKey(provider) ?: "") }
    var endpoint by rememberSaveable { mutableStateOf(settings.connection(provider).endpoint ?: "") }

    EditScaffold(
        title = provider.label,
        onBack = onDone,
        onSave = {
            if (provider.requiresApiKey) settings.setApiKey(apiKey.trim(), provider)
            settings.setEndpoint(endpoint.trim().ifEmpty { null }, provider)
            onDone()
        },
    ) {
        if (provider.requiresApiKey) {
            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it },
                label = { Text("API キー") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
            Text("API キーはこの端末の Android Keystore の鍵で暗号化して保存します。", style = MaterialTheme.typography.bodySmall)
        }
        OutlinedTextField(
            value = endpoint,
            onValueChange = { endpoint = it },
            label = { Text("エンドポイント") },
            placeholder = { Text(provider.defaultEndpoint) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        Text("空にすると ${provider.defaultEndpoint} を使います。", style = MaterialTheme.typography.bodySmall)
        if (provider == BackendProvider.Ollama || provider == BackendProvider.LmStudio) {
            Text(
                "スマートフォンの localhost は、このスマートフォン自身です。Mac などで動かしている場合は、その機械の LAN の IP アドレス (例: http://192.168.1.10:1234) を書いてください。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (endpoint.isNotEmpty()) {
            TextButton(onClick = { endpoint = "" }) { Text("デフォルトに戻す") }
        }
    }
}

@Composable
private fun GeminiNanoScreen(container: AppContainer, onDone: () -> Unit) {
    val nano = container.geminiNano
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<NanoStatus>(NanoStatus.Checking) }
    LaunchedEffect(Unit) { status = nano.status() }

    EditScaffold(title = BackendProvider.FoundationModels.label, onBack = onDone, onSave = null) {
        Text("端末の中で動くモデルです。API キーは要らず、入力は端末の外に送りません。アプリが前面にあるときだけ使えます。")
        when (val s = status) {
            NanoStatus.Checking -> Text("状態を確かめています...")
            NanoStatus.Available -> Text("使えます。", color = MaterialTheme.colorScheme.primary)
            NanoStatus.Downloadable -> {
                Text("モデルをダウンロードすると使えます。Wi-Fi でのダウンロードをおすすめします。")
                Button(onClick = {
                    scope.launch { nano.download().collect { status = it } }
                }) { Text("ダウンロード") }
            }
            is NanoStatus.Downloading -> {
                Text(if (s.bytes > 0) "ダウンロード中... ${s.bytes / 1_000_000} MB" else "ダウンロード中...")
                LinearProgressIndicator(Modifier.fillMaxWidth())
                TextButton(onClick = { scope.launch { status = nano.status() } }) { Text("状態を確かめ直す") }
            }
            is NanoStatus.Unavailable -> Text(s.reason, color = MaterialTheme.colorScheme.error)
        }
    }
}
