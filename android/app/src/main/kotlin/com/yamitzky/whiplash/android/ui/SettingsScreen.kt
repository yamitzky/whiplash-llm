package com.yamitzky.whiplash.android.ui

import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.yamitzky.whiplash.android.AppContainer
import com.yamitzky.whiplash.android.Navigation
import com.yamitzky.whiplash.android.R
import com.yamitzky.whiplash.android.Screen
import com.yamitzky.whiplash.android.WhiplashTileService
import com.yamitzky.whiplash.android.label
import com.yamitzky.whiplash.android.supportsThinking
import com.yamitzky.whiplash.shared.model.BackendProvider

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(container: AppContainer, navigation: Navigation, activity: Activity) {
    container.settingsVersion // 設定が変わったら描き直す
    val settings = container.settings
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("設定") },
                navigationIcon = { IconButton(onClick = navigation::pop) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "戻る") } },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            SectionHeader("ロール")
            container.roles.forEachIndexed { index, role ->
                ListItem(
                    headlineContent = { Text("${role.icon} ${role.name}") },
                    supportingContent = role.modelId?.let { id -> settings.models.firstOrNull { it.id == id }?.let { { Text(it.label) } } },
                    trailingContent = {
                        androidx.compose.foundation.layout.Row {
                            IconButton(onClick = { container.roleStore.move(setOf(index), index - 1) }, enabled = index > 0) {
                                Icon(Icons.Default.KeyboardArrowUp, "上へ")
                            }
                            IconButton(onClick = { container.roleStore.move(setOf(index), index + 2) }, enabled = index < container.roles.lastIndex) {
                                Icon(Icons.Default.KeyboardArrowDown, "下へ")
                            }
                        }
                    },
                    modifier = Modifier.clickable { navigation.push(Screen.RoleEdit(role.id)) },
                )
            }
            ListItem(
                headlineContent = { Text("ロールを追加") },
                leadingContent = { Icon(Icons.Default.Add, null) },
                modifier = Modifier.clickable { navigation.push(Screen.RoleEdit(null)) },
            )
            HorizontalDivider()

            SectionHeader("接続設定")
            BackendProvider.entries.forEach { provider ->
                ListItem(
                    headlineContent = { Text(provider.label) },
                    supportingContent = { Text(connectionSummary(container, provider)) },
                    modifier = Modifier.clickable { navigation.push(Screen.Provider(provider)) },
                )
            }
            HorizontalDivider()

            SectionHeader("モデル")
            settings.models.forEach { model ->
                val isDefault = model.id == settings.defaultModel?.id
                ListItem(
                    headlineContent = { Text(model.label) },
                    supportingContent = { Text("${model.provider.label} · ${model.modelIdentifier}" + if (model.provider.supportsThinking) " · ${model.thinking.label}" else "") },
                    trailingContent = if (isDefault) {
                        { Icon(Icons.Default.Star, "既定のモデル", tint = MaterialTheme.colorScheme.primary) }
                    } else {
                        null
                    },
                    modifier = Modifier.clickable { navigation.push(Screen.ModelEdit(model.id)) },
                )
            }
            ListItem(
                headlineContent = { Text("モデルを追加") },
                leadingContent = { Icon(Icons.Default.Add, null) },
                modifier = Modifier.clickable { navigation.push(Screen.ModelEdit(null)) },
            )
            HorizontalDivider()

            SectionHeader("クイック設定")
            TileRow(activity)
        }
    }
}



private fun connectionSummary(container: AppContainer, provider: BackendProvider): String {
    if (provider == BackendProvider.FoundationModels) return "端末内のモデル。API キーは要りません"
    val settings = container.settings
    val endpoint = settings.endpoint(provider)
    if (!provider.requiresApiKey) return endpoint
    return if (settings.apiKey(provider).isNullOrEmpty()) "API キー未設定" else "API キー設定済み"
}

/**
 * タイルを置くのは端末の設定なので、アプリからは追加をお願いするダイアログを出すだけにする。
 * Android 12 以前にはこの仕組みが無いので、手で追加する方法を書く。
 */
@Composable
private fun TileRow(activity: Activity) {
    var message by remember { mutableStateOf<String?>(null) }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        ListItem(
            headlineContent = { Text("クイック設定にタイルを追加") },
            supportingContent = { Text(message ?: "通知領域を下ろしてタイルを押すと、すぐに入力を始められます") },
            modifier = Modifier.clickable {
                val manager = activity.getSystemService(StatusBarManager::class.java)
                manager.requestAddTileService(
                    ComponentName(activity, WhiplashTileService::class.java),
                    "Whiplash",
                    Icon.createWithResource(activity, R.drawable.ic_tile),
                    activity.mainExecutor,
                ) { code ->
                    message = when (code) {
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "タイルを追加しました"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "タイルはもう追加されています"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "追加しませんでした"
                        else -> "追加できませんでした (コード $code)"
                    }
                }
            },
        )
    } else {
        ListItem(
            headlineContent = { Text("クイック設定のタイル") },
            supportingContent = { Text("通知領域を下ろして編集ボタンを押し、「Whiplash」のタイルを追加してください") },
        )
    }
}

@Composable
fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}
