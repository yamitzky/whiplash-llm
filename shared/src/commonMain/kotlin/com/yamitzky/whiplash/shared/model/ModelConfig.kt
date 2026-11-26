package com.yamitzky.whiplash.shared.model

import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/** Swift の `UUID` と同じ文字列で ID を作り、読む。 */
object WhiplashId {
    private val pattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    @OptIn(ExperimentalUuidApi::class)
    fun random(): String = Uuid.random().toHexDashString().uppercase()

    /** Swift の `UUID(uuidString:)` が読める形なら、Swift が書き戻すときの大文字の形にして返す。 */
    fun normalize(value: String): String? = if (pattern.matches(value)) value.uppercase() else null
}

/** WhiplashCore の `BackendProvider`。 */
enum class BackendProvider(val rawValue: String, val displayName: String, val requiresApiKey: Boolean, val defaultEndpoint: String) {
    FoundationModels("foundationModels", "Apple Foundation Models", false, "local://foundation-models"),
    Ollama("ollama", "Ollama", false, "http://localhost:11434"),
    LmStudio("lmStudio", "LM Studio", false, "http://localhost:1234"),
    OpenAI("openAI", "OpenAI", true, "https://api.openai.com/v1/"),
    Anthropic("anthropic", "Anthropic", true, "https://api.anthropic.com/"),
    Gemini("gemini", "Google Gemini", true, "https://generativelanguage.googleapis.com/"),
    OpenResponses("openResponses", "Open Responses", true, "https://openrouter.ai/api/v1/"),
    ;

    companion object {
        fun fromRawValue(rawValue: String): BackendProvider? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** WhiplashCore の `ProviderConnection`。[apiKey] は Keychain へ移す前の古いデータにだけ入っている。 */
data class ProviderConnection(
    val apiKey: String? = null,
    val endpoint: String? = null,
)

/** WhiplashCore の `ThinkingConfig`。 */
sealed class ThinkingConfig {
    data object Off : ThinkingConfig()
    data object Auto : ThinkingConfig()
    data class Budget(val tokens: Int) : ThinkingConfig()

    val label: String
        get() = when (this) {
            Off -> "オフ"
            Auto -> "自動"
            is Budget -> "Budget: $tokens"
        }
}

/** WhiplashCore の `ModelConfig`。 */
data class ModelConfig(
    val id: String = WhiplashId.random(),
    val name: String,
    val provider: BackendProvider,
    val modelIdentifier: String,
    val thinking: ThinkingConfig = ThinkingConfig.Off,
) {
    companion object {
        /** Swift の `ModelConfig.builtinDefaults`。ID は Swift と同じく、プロセスを起動するたびに変わる。 */
        val builtinDefaults: List<ModelConfig> = listOf(
            ModelConfig(name = "Foundation Models", provider = BackendProvider.FoundationModels, modelIdentifier = "default"),
            ModelConfig(name = "Claude Haiku", provider = BackendProvider.Anthropic, modelIdentifier = "claude-haiku-4-5-20251001"),
            ModelConfig(name = "Claude Sonnet", provider = BackendProvider.Anthropic, modelIdentifier = "claude-sonnet-4-5-20250929"),
            ModelConfig(name = "Claude Opus", provider = BackendProvider.Anthropic, modelIdentifier = "claude-opus-4-5-20250929"),
            ModelConfig(name = "GPT-4o mini", provider = BackendProvider.OpenAI, modelIdentifier = "gpt-4o-mini"),
            ModelConfig(name = "GPT-4o", provider = BackendProvider.OpenAI, modelIdentifier = "gpt-4o"),
            ModelConfig(name = "Gemini 2.5 Flash", provider = BackendProvider.Gemini, modelIdentifier = "gemini-2.5-flash"),
            ModelConfig(name = "Gemini 2.5 Pro", provider = BackendProvider.Gemini, modelIdentifier = "gemini-2.5-pro"),
            ModelConfig(name = "Llama 3.2 (Ollama)", provider = BackendProvider.Ollama, modelIdentifier = "llama3.2"),
        )
    }
}
