package com.yamitzky.whiplash.android

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamitzky.whiplash.shared.llm.LlmService
import com.yamitzky.whiplash.shared.llm.openai.OpenAiChatCompletionsProvider
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.store.SettingsStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** 設定ダイアログで入れる 3 つの値。 */
data class ConnectionForm(val endpoint: String, val modelIdentifier: String, val apiKey: String)

/**
 * 1 画面分の状態。設定は共有コアの [SettingsStore] に、Mac や iOS と同じ形式で保存する。
 *
 * この版が使うのは、[BackendProvider.OpenAI] の接続先と API キー、名前が [MODEL_NAME] のモデル 1 つだけ。
 * OpenAI 互換のサーバーなら OpenAI 以外 (LM Studio、Ollama、OpenRouter) にもこの 1 つで届く。
 */
class ChatViewModel(application: Application) : AndroidViewModel(application) {
    private val settings = SettingsStore(
        defaults = SharedPreferencesKeyValueStore(application.getSharedPreferences("whiplash.defaults", Context.MODE_PRIVATE)),
        secrets = KeystoreSecretStore(application.getSharedPreferences("whiplash.secrets", Context.MODE_PRIVATE)),
    )
    private val openAiCompatible = OpenAiChatCompletionsProvider()
    private val service = LlmService(settings, providerFor = { provider ->
        openAiCompatible.takeIf { provider == BackendProvider.OpenAI }
    })

    var input by mutableStateOf("")
    var output by mutableStateOf("")
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var isGenerating by mutableStateOf(false)
        private set

    private var generation: Job? = null

    private val model: ModelConfig?
        get() = settings.models.firstOrNull { it.name == MODEL_NAME && it.provider == BackendProvider.OpenAI }

    val isConfigured: Boolean get() = model != null && settings.connection(BackendProvider.OpenAI).endpoint != null

    fun connectionForm(): ConnectionForm = ConnectionForm(
        endpoint = settings.connection(BackendProvider.OpenAI).endpoint ?: "",
        modelIdentifier = model?.modelIdentifier ?: "",
        apiKey = settings.apiKey(BackendProvider.OpenAI) ?: "",
    )

    fun saveConnection(form: ConnectionForm) {
        settings.setEndpoint(form.endpoint.trim().ifEmpty { null }, BackendProvider.OpenAI)
        settings.setApiKey(form.apiKey.trim(), BackendProvider.OpenAI)
        val current = model
        val identifier = form.modelIdentifier.trim()
        if (current == null) {
            settings.addModel(ModelConfig(name = MODEL_NAME, provider = BackendProvider.OpenAI, modelIdentifier = identifier))
        } else {
            settings.updateModel(current.copy(modelIdentifier = identifier))
        }
    }

    fun send() {
        val text = input.trim()
        val model = model ?: return
        if (text.isEmpty() || isGenerating) return
        // ロールの機能はまだ無いので、指示の無いロールをその場で作る。RoleStore には保存しない。
        val role = Role(name = "Android", icon = "", systemPrompt = "", responsePatterns = listOf(ResponsePattern.RichMessage), modelId = model.id)
        output = ""
        error = null
        isGenerating = true
        generation = viewModelScope.launch {
            try {
                val response = service.generateStreamingResponse(text, role) { partial -> output = partial }
                output = response.text
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: e.toString()
            } finally {
                isGenerating = false
            }
        }
    }

    fun stop() {
        generation?.cancel()
    }

    companion object {
        const val MODEL_NAME = "Android (OpenAI 互換)"
    }
}
