package com.yamitzky.whiplash.shared.llm

import com.yamitzky.whiplash.shared.model.ModelConfig
import kotlin.coroutines.cancellation.CancellationException

/** 送る画像 1 枚。 */
class LlmImage(val data: ByteArray, val mimeType: String)

/**
 * プロバイダーに渡す 1 回分の依頼。[LlmService] がロールと設定から組み立てる。
 * プロバイダーの実装はこれだけを見て送り、SettingsStore や RoleStore を読まない。
 */
data class LlmRequest(
    val model: ModelConfig,
    /** 設定の接続先。空なら [com.yamitzky.whiplash.shared.model.BackendProvider.defaultEndpoint]。 */
    val endpoint: String,
    val apiKey: String?,
    /** ロールの指示。system として送る。 */
    val instructions: String,
    /** 利用者が渡した本文に追加指示を足したもの。[Prompt.build] が組み立てる。 */
    val prompt: String,
    val images: List<LlmImage> = emptyList(),
)

/** 生成途中の状態。[reasoning] は thinking の本文で、届かないプロバイダーでは空のまま。 */
data class LlmSnapshot(val content: String, val reasoning: String = "") {
    /** UI が `<thinking>` タグで分割して表示する形。 */
    val displayText: String get() = Prompt.displayText(content, listOf(reasoning))
}

/**
 * LLM の呼び出し口。共有コアに置くのはこのインターフェースだけで、実装は OS ごとに置ける。
 * 例: Android は Ktor の [com.yamitzky.whiplash.shared.llm.openai.OpenAiChatCompletionsProvider]、
 * macOS と iOS は将来、Swift の AnyLanguageModel を包んだ実装を Swift 側から渡す。
 *
 * Swift から SKIE なしで呼べるよう、引数はコールバックと suspend 関数だけにしている。
 */
interface LlmProvider {
    /**
     * [onPartial] は届いた分を足した状態を、変わるたびに渡す。戻り値は最後の状態。
     * 失敗は [LlmException] で返す。
     */
    @Throws(LlmException::class, CancellationException::class)
    suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot
}

/** LLM の呼び出しの失敗。[statusCode] は HTTP の応答が返ったときだけ入る。 */
class LlmException(
    message: String,
    val statusCode: Int? = null,
    cause: Throwable? = null,
) : Exception(message, cause)
