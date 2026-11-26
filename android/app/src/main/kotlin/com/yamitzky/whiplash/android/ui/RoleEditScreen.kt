package com.yamitzky.whiplash.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.yamitzky.whiplash.android.AppContainer
import com.yamitzky.whiplash.android.label
import com.yamitzky.whiplash.shared.model.ImageInputMode
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role

@Composable
fun RoleEditScreen(container: AppContainer, roleId: String?, onDone: () -> Unit) {
    val original = container.roles.firstOrNull { it.id == roleId }
    var icon by rememberSaveable { mutableStateOf(original?.icon ?: "✨") }
    var name by rememberSaveable { mutableStateOf(original?.name ?: "") }
    var prompt by rememberSaveable { mutableStateOf(original?.systemPrompt ?: "") }
    var copies by rememberSaveable { mutableStateOf(original?.copiesToClipboard ?: false) }
    var imageMode by rememberSaveable { mutableStateOf((original?.imageInputMode ?: ImageInputMode.Image).rawValue) }
    var modelId by rememberSaveable { mutableStateOf(original?.modelId) }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }

    EditScaffold(
        title = if (original == null) "ロールを追加" else "ロールを編集",
        onBack = onDone,
        saveEnabled = name.isNotBlank(),
        onSave = {
            val base = original ?: Role(name = name, icon = icon, systemPrompt = prompt, responsePatterns = listOf(ResponsePattern.RichMessage))
            // copiesToClipboard の切り替えは、Swift の setter と同じく responsePatterns を作り直す。
            // 切り替えていないときは元の値を残す。ほかのビルドが書いた値を消さないため。
            val withPatterns = if (base.copiesToClipboard != copies) base.withCopiesToClipboard(copies) else base
            val role = withPatterns.copy(
                name = name.trim(),
                icon = icon.trim().ifEmpty { "✨" },
                systemPrompt = prompt,
                imageInputMode = ImageInputMode.fromRawValue(imageMode) ?: ImageInputMode.Image,
                modelId = modelId,
            )
            if (original == null) container.roleStore.add(role) else container.roleStore.update(role)
            onDone()
        },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = icon, onValueChange = { icon = it }, label = { Text("アイコン") }, singleLine = true, modifier = Modifier.width(96.dp))
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("名前") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(start = 8.dp),
            )
        }
        OutlinedTextField(
            value = prompt,
            onValueChange = { prompt = it },
            label = { Text("システムプロンプト") },
            minLines = 5,
            modifier = Modifier.fillMaxWidth(),
        )
        SwitchRow("結果を自動でクリップボードにコピー", copies) { copies = it }
        SectionTitle("画像の入力方式")
        RadioGroup(
            options = listOf(ImageInputMode.Image.rawValue to "画像のまま送る", ImageInputMode.Ocr.rawValue to "文字を読み取って (OCR) テキストで送る"),
            selected = imageMode,
            onSelect = { imageMode = it },
        )
        container.settingsVersion
        val defaultName = container.settings.defaultModel?.label ?: "未設定"
        Dropdown(
            label = "使うモデル",
            options = listOf<Pair<String?, String>>(null to "既定 ($defaultName)") + container.settings.models.map { it.id to "${it.label} (${it.provider.label})" },
            selected = modelId,
            onSelect = { modelId = it },
        )
        if (original != null) {
            OutlinedButton(onClick = { confirmDelete = true }) { Text("このロールを削除", color = MaterialTheme.colorScheme.error) }
        }
    }

    if (confirmDelete && original != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("「${original.name}」を削除しますか") },
            confirmButton = {
                TextButton(onClick = {
                    container.roleStore.delete(original)
                    confirmDelete = false
                    onDone()
                }) { Text("削除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("キャンセル") } },
        )
    }
}

/** 文字の部分を押しても切り替わるスイッチの行。 */
@Composable
fun SwitchRow(text: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().toggleable(value = checked, enabled = enabled, role = androidx.compose.ui.semantics.Role.Switch, onValueChange = onChange),
    ) {
        Text(text, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}
