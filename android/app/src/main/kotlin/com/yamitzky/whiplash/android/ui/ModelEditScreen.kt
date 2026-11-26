package com.yamitzky.whiplash.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import com.yamitzky.whiplash.android.AppContainer
import com.yamitzky.whiplash.android.label
import com.yamitzky.whiplash.android.supportsThinking
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ThinkingConfig

private const val THINKING_OFF = "off"
private const val THINKING_AUTO = "auto"
private const val THINKING_BUDGET = "budget"

@Composable
fun ModelEditScreen(container: AppContainer, modelId: String?, onDone: () -> Unit) {
    val settings = container.settings
    val original = settings.models.firstOrNull { it.id == modelId }
    var provider by rememberSaveable { mutableStateOf((original?.provider ?: BackendProvider.OpenAI).rawValue) }
    var name by rememberSaveable { mutableStateOf(original?.name ?: "") }
    var identifier by rememberSaveable { mutableStateOf(original?.modelIdentifier ?: "") }
    var thinkingMode by rememberSaveable {
        mutableStateOf(
            when (original?.thinking) {
                ThinkingConfig.Auto -> THINKING_AUTO
                is ThinkingConfig.Budget -> THINKING_BUDGET
                else -> THINKING_OFF
            },
        )
    }
    var budget by rememberSaveable { mutableStateOf(((original?.thinking as? ThinkingConfig.Budget)?.tokens ?: 4096).toString()) }
    var makeDefault by rememberSaveable { mutableStateOf(original != null && settings.defaultModel?.id == original.id) }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }

    val backend = BackendProvider.fromRawValue(provider) ?: BackendProvider.OpenAI
    val isOnDevice = backend == BackendProvider.FoundationModels
    val budgetTokens = budget.toIntOrNull()
    val valid = name.isNotBlank() && (isOnDevice || identifier.isNotBlank()) && (thinkingMode != THINKING_BUDGET || (budgetTokens != null && budgetTokens > 0))

    EditScaffold(
        title = if (original == null) "モデルを追加" else "モデルを編集",
        onBack = onDone,
        saveEnabled = valid,
        onSave = {
            val thinking = if (!backend.supportsThinking) {
                ThinkingConfig.Off
            } else {
                when (thinkingMode) {
                    THINKING_AUTO -> ThinkingConfig.Auto
                    THINKING_BUDGET -> ThinkingConfig.Budget(budgetTokens ?: 4096)
                    else -> ThinkingConfig.Off
                }
            }
            val edited = (original ?: ModelConfig(name = name, provider = backend, modelIdentifier = identifier)).copy(
                name = name.trim(),
                provider = backend,
                // 端末内モデルはモデル ID を使わない。Swift のプリセットと同じ "default" を入れておく。
                modelIdentifier = if (isOnDevice) "default" else identifier.trim(),
                thinking = thinking,
            )
            if (original == null) settings.addModel(edited) else settings.updateModel(edited)
            if (makeDefault) settings.defaultModelId = edited.id
            onDone()
        },
    ) {
        Dropdown(
            label = "プロバイダー",
            options = BackendProvider.entries.map { it.rawValue to it.label },
            selected = provider,
            onSelect = { provider = it },
        )
        OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("表示名") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (!isOnDevice) {
            OutlinedTextField(
                value = identifier,
                onValueChange = { identifier = it },
                label = { Text("モデル ID") },
                placeholder = { Text(exampleModelId(backend)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (backend.supportsThinking) {
            SectionTitle("Thinking")
            RadioGroup(
                options = listOf(THINKING_OFF to "オフ", THINKING_AUTO to "自動", THINKING_BUDGET to "トークン数を指定"),
                selected = thinkingMode,
                onSelect = { thinkingMode = it },
            )
            if (thinkingMode == THINKING_BUDGET) {
                OutlinedTextField(
                    value = budget,
                    onValueChange = { budget = it.filter(Char::isDigit) },
                    label = { Text("トークン数") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        // 既定のモデルを外す操作は無い。別のモデルを既定にすると入れ替わる。
        SwitchRow("既定のモデルにする", makeDefault, enabled = !(original != null && settings.defaultModel?.id == original.id)) { makeDefault = it }
        if (original != null) {
            OutlinedButton(onClick = { confirmDelete = true }) { Text("このモデルを削除", color = MaterialTheme.colorScheme.error) }
        }
    }

    if (confirmDelete && original != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("「${original.label}」を削除しますか") },
            text = { Text("このモデルを使っているロールは、既定のモデルを使うようになります。") },
            confirmButton = {
                TextButton(onClick = {
                    settings.deleteModel(original.id)
                    confirmDelete = false
                    onDone()
                }) { Text("削除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("キャンセル") } },
        )
    }
}

private fun exampleModelId(provider: BackendProvider): String = when (provider) {
    BackendProvider.Anthropic -> "claude-sonnet-4-5-20250929"
    BackendProvider.OpenAI -> "gpt-4o-mini"
    BackendProvider.Gemini -> "gemini-2.5-flash"
    BackendProvider.OpenResponses -> "openai/gpt-4o-mini"
    BackendProvider.Ollama -> "llama3.2"
    BackendProvider.LmStudio -> "qwen3-8b"
    BackendProvider.FoundationModels -> "default"
}
