package com.yamitzky.whiplash.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.yamitzky.whiplash.shared.llm.LlmProvider
import com.yamitzky.whiplash.shared.llm.LlmService
import com.yamitzky.whiplash.shared.llm.anthropic.AnthropicMessagesProvider
import com.yamitzky.whiplash.shared.llm.gemini.GeminiProvider
import com.yamitzky.whiplash.shared.llm.openai.OpenAiChatCompletionsProvider
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.store.RoleStore
import com.yamitzky.whiplash.shared.store.SettingsStore

/**
 * 保存先、ストア、プロバイダーをまとめて持つ。
 * ストアは Mac と iOS の UserDefaults と同じく、1 つの保存先 (`whiplash.defaults`) にロールと設定を置く。
 */
class AppContainer(context: Context) {
    private val defaults = SharedPreferencesKeyValueStore(context.getSharedPreferences("whiplash.defaults", Context.MODE_PRIVATE))

    val settings = SettingsStore(
        defaults = defaults,
        secrets = KeystoreSecretStore(context.getSharedPreferences("whiplash.secrets", Context.MODE_PRIVATE)),
    )
    val roleStore = RoleStore(defaults)

    /** Compose が設定の変更で描き直すための番号。SettingsStore はコールバックでしか変更を知らせない。 */
    var settingsVersion by mutableIntStateOf(0)
        private set
    var roles by mutableStateOf<List<Role>>(emptyList())
        private set

    val geminiNano = GeminiNanoProvider()
    private val openAiCompatible = OpenAiChatCompletionsProvider()
    private val anthropic = AnthropicMessagesProvider()
    private val gemini = GeminiProvider()

    val llm = LlmService(settings, providerFor = ::provider)

    init {
        settings.onChange = { settingsVersion++ }
        roleStore.onChange = { roles = it }
        roleStore.load()
        roles = roleStore.roles
    }

    private fun provider(provider: BackendProvider): LlmProvider = when (provider) {
        // Android では Apple Foundation Models の枠を端末内の Gemini Nano に使う。保存形式に値を足さないため。
        BackendProvider.FoundationModels -> geminiNano
        BackendProvider.Ollama, BackendProvider.LmStudio, BackendProvider.OpenAI, BackendProvider.OpenResponses -> openAiCompatible
        BackendProvider.Anthropic -> anthropic
        BackendProvider.Gemini -> gemini
    }
}
