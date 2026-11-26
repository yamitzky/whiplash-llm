package com.yamitzky.whiplash.shared.llm

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.store.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/** 生成の結果。[text] は [LlmSnapshot.displayText] と同じ形。 */
data class LlmResponse(val text: String)

/** [LlmService.startStreamingResponse] が返す。Swift の Task のキャンセルに相当する。 */
fun interface LlmCancellation {
    fun cancel()
}

/**
 * WhiplashCore の `LLMService`。ロールと設定から [LlmRequest] を組み立て、プロバイダーに渡す。
 *
 * @param providerFor プロバイダーごとの実装を返す。この端末で使えないプロバイダーには null を返す。
 */
class LlmService(
    private val settings: SettingsStore,
    private val providerFor: (BackendProvider) -> LlmProvider?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    @Throws(LlmException::class)
    fun buildRequest(
        fullText: String,
        role: Role,
        additionalInstructions: String? = null,
        images: List<LlmImage> = emptyList(),
    ): LlmRequest {
        val model = settings.model(role.modelId)
            ?: throw LlmException("${BackendProvider.FoundationModels.displayName} はこのデバイスでは利用できません。設定から別のモデルを選択してください。")
        return LlmRequest(
            model = model,
            endpoint = settings.endpoint(model.provider),
            apiKey = settings.apiKey(model.provider),
            instructions = role.systemPrompt,
            prompt = Prompt.build(fullText, additionalInstructions),
            images = images,
        )
    }

    /** [onPartialResponse] は `<thinking>` を含む表示用の文字列を、変わるたびに受け取る。 */
    @Throws(LlmException::class, CancellationException::class)
    suspend fun generateStreamingResponse(
        fullText: String,
        role: Role,
        additionalInstructions: String? = null,
        images: List<LlmImage> = emptyList(),
        onPartialResponse: (String) -> Unit,
    ): LlmResponse {
        val request = buildRequest(fullText, role, additionalInstructions, images)
        val provider = providerFor(request.model.provider)
            ?: throw LlmException("${request.model.provider.displayName} はこのデバイスでは利用できません。設定から別のモデルを選択してください。")
        val last = provider.streamResponse(request) { onPartialResponse(it.displayText) }
        return LlmResponse(last.displayText)
    }

    /**
     * コールバックだけで使える版。Swift の async から Kotlin の suspend 関数を呼ぶと、
     * SKIE なしでは Swift の Task をキャンセルしても Kotlin 側の通信が止まらないので、止める口を返す。
     * コールバックは [scope] のスレッドで呼ぶ。UI を触る側で main に移す。
     * キャンセルしたときは [onCompletion] を呼ばない。
     */
    fun startStreamingResponse(
        fullText: String,
        role: Role,
        additionalInstructions: String?,
        images: List<LlmImage>,
        onPartialResponse: (String) -> Unit,
        onCompletion: (LlmResponse?, Throwable?) -> Unit,
    ): LlmCancellation {
        val job: Job = scope.launch {
            val result = try {
                Result.success(generateStreamingResponse(fullText, role, additionalInstructions, images, onPartialResponse))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Result.failure(e)
            }
            onCompletion(result.getOrNull(), result.exceptionOrNull())
        }
        return LlmCancellation { job.cancel() }
    }
}
