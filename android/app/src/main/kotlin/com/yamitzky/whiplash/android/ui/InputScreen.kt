package com.yamitzky.whiplash.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mikepenz.markdown.m3.Markdown
import com.yamitzky.whiplash.android.AppContainer
import com.yamitzky.whiplash.android.Attachment
import com.yamitzky.whiplash.android.GenerationResult
import com.yamitzky.whiplash.android.InputViewModel
import com.yamitzky.whiplash.android.label
import com.yamitzky.whiplash.android.splitThinking
import com.yamitzky.whiplash.shared.model.Role

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InputScreen(viewModel: InputViewModel, container: AppContainer, onOpenSettings: () -> Unit) {
    val snackbar = remember { SnackbarHostState() }
    val keyboard = LocalSoftwareKeyboardController.current
    val pickImages = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(5)) { uris ->
        viewModel.addImages(uris)
    }
    val onPickImages = { pickImages.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    LaunchedEffect(viewModel.notice) {
        viewModel.notice?.let {
            snackbar.showSnackbar(it)
            viewModel.notice = null
        }
    }

    val result = viewModel.result
    val hasInput = viewModel.attachments.isNotEmpty() || viewModel.inputText.isNotBlank()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Whiplash") },
                actions = {
                    if (result != null || hasInput) {
                        TextButton(onClick = viewModel::startNew) { Text("新規") }
                    }
                    IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, contentDescription = "設定") }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .imePadding()
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (result == null) {
                InputContent(
                    viewModel = viewModel,
                    roles = container.roles,
                    modelName = { role -> container.settingsVersion.let { container.settings.model(role.modelId)?.label } },
                    onPickImages = onPickImages,
                    onSend = { role ->
                        keyboard?.hide()
                        if (role == null) viewModel.ask() else viewModel.send(role)
                    },
                )
            } else {
                ResultContent(result, viewModel, onSubmitFollowUp = {
                    keyboard?.hide()
                    viewModel.followUp()
                })
            }
        }
    }
}

@Composable
private fun InputContent(
    viewModel: InputViewModel,
    roles: List<Role>,
    modelName: (Role) -> String?,
    onPickImages: () -> Unit,
    onSend: (Role?) -> Unit,
) {
    val attachments = viewModel.attachments
    if (attachments.isEmpty()) {
        Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("テキストや画像を追加して\nAI に処理してもらおう", style = MaterialTheme.typography.titleMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.size(8.dp))
            Text(
                "ほかのアプリで文字を選んで「Whiplash」を選ぶか、共有から送っても始められます",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton(onClick = viewModel::pasteFromClipboard) {
                Icon(Icons.Default.ContentPaste, contentDescription = null)
                Spacer(Modifier.size(6.dp))
                Text("貼り付け")
            }
            FilledTonalButton(onClick = onPickImages) {
                Icon(Icons.Default.Image, contentDescription = null)
                Spacer(Modifier.size(6.dp))
                Text("画像を選ぶ")
            }
        }
    } else {
        attachments.forEach { AttachmentCard(it, onRemove = { viewModel.remove(it) }) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = viewModel::pasteFromClipboard) { Text("貼り付け") }
            OutlinedButton(onClick = onPickImages) { Text("画像を追加") }
        }
    }

    OutlinedTextField(
        value = viewModel.inputText,
        onValueChange = { viewModel.inputText = it },
        label = { Text(if (attachments.isEmpty()) "直接入力する" else "追加の指示 (任意)") },
        modifier = Modifier.fillMaxWidth(),
        minLines = if (attachments.isEmpty()) 3 else 2,
        maxLines = 8,
    )

    if (attachments.isNotEmpty() || viewModel.inputText.isNotBlank()) {
        RoleGrid(roles, modelName, onSend)
    }
}

@Composable
private fun AttachmentCard(attachment: Attachment, onRemove: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Box {
            when (attachment) {
                is Attachment.Text -> Text(
                    attachment.text,
                    modifier = Modifier.padding(start = 12.dp, top = 12.dp, bottom = 12.dp, end = 44.dp),
                    maxLines = 6,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                )
                is Attachment.Image -> Image(
                    attachment.preview,
                    contentDescription = "添付した画像",
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp),
                    contentScale = ContentScale.Fit,
                )
            }
            IconButton(onClick = onRemove, modifier = Modifier.align(Alignment.TopEnd)) {
                Icon(Icons.Default.Close, contentDescription = "外す")
            }
        }
    }
}

/** iOS の roleGrid と同じく 2 列。最後に、ロールを使わない「質問する」を置く。 */
@Composable
private fun RoleGrid(roles: List<Role>, modelName: (Role) -> String?, onSend: (Role?) -> Unit) {
    val buttons: List<Role?> = roles + listOf(null)
    buttons.chunked(2).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            row.forEach { role ->
                Button(
                    onClick = { onSend(role) },
                    modifier = Modifier.weight(1f).heightIn(min = 56.dp),
                    colors = if (role == null) {
                        ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.tertiary, contentColor = MaterialTheme.colorScheme.onTertiary)
                    } else {
                        ButtonDefaults.buttonColors()
                    },
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(if (role == null) "⚡ 質問する" else "${role.icon} ${role.name}", maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val model = if (role == null) null else modelName(role)
                        if (model != null && role?.modelId != null) {
                            Text(model, style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
            if (row.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun ResultContent(result: GenerationResult, viewModel: InputViewModel, onSubmitFollowUp: () -> Unit) {
    val (thinking, body) = splitThinking(result.text)
    var showThinking by rememberSaveable(result) { mutableStateOf(false) }

    Text(result.title, style = MaterialTheme.typography.titleMedium)
    if (result.inputSummary.isNotEmpty()) {
        Text(
            result.inputSummary,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
    if (result.isStreaming) LinearProgressIndicator(Modifier.fillMaxWidth())

    if (thinking != null) {
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                TextButton(onClick = { showThinking = !showThinking }, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
                    Text(if (body.isEmpty() && result.isStreaming) "思考中..." else if (showThinking) "思考を隠す" else "思考を見る")
                }
                if (showThinking || (body.isEmpty() && result.isStreaming)) {
                    Text(thinking, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }

    if (body.isNotEmpty()) {
        Card(Modifier.fillMaxWidth()) {
            SelectionContainer(Modifier.padding(16.dp)) {
                Markdown(content = body)
            }
        }
    } else if (result.isStreaming && thinking == null) {
        Text("生成中...", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }

    result.error?.let {
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer), modifier = Modifier.fillMaxWidth()) {
            Text(it, modifier = Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
        }
    }

    if (result.isStreaming) {
        OutlinedButton(onClick = viewModel::stop) {
            Icon(Icons.Default.Stop, contentDescription = null)
            Spacer(Modifier.size(6.dp))
            Text("停止")
        }
        return
    }

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalButton(onClick = viewModel::copyResult, enabled = body.isNotEmpty()) {
            Icon(Icons.Default.ContentCopy, contentDescription = null)
            Spacer(Modifier.size(6.dp))
            Text("コピー")
        }
        OutlinedButton(onClick = viewModel::regenerate) {
            Icon(Icons.Default.Refresh, contentDescription = null)
            Spacer(Modifier.size(6.dp))
            Text("再生成")
        }
    }

    if (body.isNotEmpty()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = viewModel.followUpText,
                onValueChange = { viewModel.followUpText = it },
                label = { Text("追加の指示") },
                modifier = Modifier.weight(1f),
                maxLines = 4,
            )
            IconButton(onClick = onSubmitFollowUp, enabled = viewModel.followUpText.isNotBlank()) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "送る")
            }
        }
    }
}
