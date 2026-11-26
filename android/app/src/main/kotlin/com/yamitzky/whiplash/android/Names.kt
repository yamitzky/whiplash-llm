package com.yamitzky.whiplash.android

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig

/** 画面に出す名前。保存する値は変えず、Android で意味の変わる端末内モデルだけ呼び名を変える。 */
val BackendProvider.label: String
    get() = when (this) {
        BackendProvider.FoundationModels -> "Gemini Nano (端末内)"
        BackendProvider.OpenResponses -> "OpenRouter"
        else -> displayName
    }

/** プリセットのモデル名 "Foundation Models" は Android では Gemini Nano を指すので、そう見せる。 */
val ModelConfig.label: String
    get() = if (provider == BackendProvider.FoundationModels && name == "Foundation Models") "Gemini Nano" else name

/** WhiplashCore の `BackendProvider.supportsThinking`。 */
val BackendProvider.supportsThinking: Boolean
    get() = when (this) {
        BackendProvider.Anthropic, BackendProvider.Gemini, BackendProvider.OpenAI, BackendProvider.OpenResponses -> true
        BackendProvider.FoundationModels, BackendProvider.Ollama, BackendProvider.LmStudio -> false
    }
