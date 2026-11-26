package com.yamitzky.whiplash.android

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModel
import com.yamitzky.whiplash.android.ui.InputScreen
import com.yamitzky.whiplash.android.ui.ModelEditScreen
import com.yamitzky.whiplash.android.ui.ProviderScreen
import com.yamitzky.whiplash.android.ui.RoleEditScreen
import com.yamitzky.whiplash.android.ui.SettingsScreen
import com.yamitzky.whiplash.shared.model.BackendProvider

/** 画面の積み重ね。画面が 5 つしかないので、ナビゲーションのライブラリを使わずに持つ。 */
sealed class Screen {
    data object Input : Screen()
    data object Settings : Screen()
    data class RoleEdit(val roleId: String?) : Screen()
    data class Provider(val provider: BackendProvider) : Screen()
    data class ModelEdit(val modelId: String?) : Screen()
}

class Navigation : ViewModel() {
    val stack = mutableStateListOf<Screen>(Screen.Input)
    val current: Screen get() = stack.last()

    fun push(screen: Screen) { stack.add(screen) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    fun reset() { stack.clear(); stack.add(Screen.Input) }
}

/**
 * 入口はすべてこの Activity に来る (ランチャー、文字選択メニュー、共有、タイル)。
 * launchMode は singleTask で、2 回目以降の入力は onNewIntent で受ける。
 */
class MainActivity : ComponentActivity() {
    private val input: InputViewModel by viewModels()
    private val navigation: Navigation by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // 画面の回転で作り直されたときは、同じ Intent をもう一度受けない。
        // savedInstanceState では判断しない。プロセスが終わった後のタスクに新しい Intent が届くと、
        // 保存した状態から作り直されつつ新しい Intent を持って onCreate に来るため。
        if (!input.receivedLaunchIntent) {
            input.receivedLaunchIntent = true
            receive(intent)
        }
        setContent {
            WhiplashTheme {
                BackHandler(enabled = navigation.stack.size > 1) { navigation.pop() }
                val container = (application as WhiplashApplication).container
                when (val screen = navigation.current) {
                    Screen.Input -> InputScreen(input, container, onOpenSettings = { navigation.push(Screen.Settings) })
                    Screen.Settings -> SettingsScreen(container, navigation, this)
                    is Screen.RoleEdit -> RoleEditScreen(container, screen.roleId, onDone = navigation::pop)
                    is Screen.Provider -> ProviderScreen(container, screen.provider, onDone = navigation::pop)
                    is Screen.ModelEdit -> ModelEditScreen(container, screen.modelId, onDone = navigation::pop)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }

    private fun receive(intent: Intent) {
        if (intent.action != Intent.ACTION_MAIN) navigation.reset()
        input.handleIntent(intent)
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
