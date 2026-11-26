package com.yamitzky.whiplash.android

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.content
import com.google.mlkit.genai.prompt.generateContentRequest
import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmProvider
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** 設定画面に出す Gemini Nano の状態。 */
sealed class NanoStatus {
    data object Checking : NanoStatus()
    data object Available : NanoStatus()
    data object Downloadable : NanoStatus()
    data class Downloading(val bytes: Long) : NanoStatus()
    data class Unavailable(val reason: String) : NanoStatus()
}

/**
 * 端末内の Gemini Nano (ML Kit GenAI Prompt API) で生成する。
 * モデルは AICore が持ち、未ダウンロードなら [download] で取りに行く。
 * 推論はアプリが前面にあるときしか許されない (AICore の制限)。
 */
class GeminiNanoProvider : LlmProvider {
    private val model: GenerativeModel by lazy { Generation.getClient() }

    suspend fun status(): NanoStatus = try {
        when (model.checkStatus()) {
            FeatureStatus.AVAILABLE -> NanoStatus.Available
            FeatureStatus.DOWNLOADABLE -> NanoStatus.Downloadable
            FeatureStatus.DOWNLOADING -> NanoStatus.Downloading(0)
            else -> NanoStatus.Unavailable("この端末では Gemini Nano を使えません")
        }
    } catch (e: GenAiException) {
        NanoStatus.Unavailable(message(e))
    }

    fun download(): Flow<NanoStatus> = model.download().map { status ->
        when (status) {
            is DownloadStatus.DownloadStarted -> NanoStatus.Downloading(0)
            is DownloadStatus.DownloadProgress -> NanoStatus.Downloading(status.totalBytesDownloaded)
            DownloadStatus.DownloadCompleted -> NanoStatus.Available
            is DownloadStatus.DownloadFailed -> NanoStatus.Unavailable(message(status.e))
        }
    }

    override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
        when (status()) {
            NanoStatus.Available -> Unit
            NanoStatus.Downloadable, is NanoStatus.Downloading ->
                throw LlmException("Gemini Nano のモデルがまだ端末にありません。設定の「接続設定」>「Gemini Nano (端末内)」からダウンロードしてください。")
            is NanoStatus.Unavailable, NanoStatus.Checking ->
                throw LlmException("この端末では Gemini Nano を使えません。設定から別のモデルを選んでください。")
        }
        // 画像が何枚でも同じ形で送れるよう、1 つの Content に画像と本文を並べ、system は Builder に渡す。
        val userContent = content {
            request.images.forEach { addPart(ImagePart(it.data)) }
            // 画像だけを送るときは本文が空になる。空の本文は送らない。
            if (request.prompt.isNotEmpty() || request.images.isEmpty()) addPart(TextPart(request.prompt))
        }
        val generateRequest = generateContentRequest(userContent) {
            if (request.instructions.isNotEmpty()) systemInstruction = SystemInstruction(request.instructions)
        }
        val content = StringBuilder()
        try {
            model.generateContentStream(generateRequest).collect { response ->
                val chunk = response.candidates.firstOrNull()?.text ?: return@collect
                // 届く値が差分か累積かを文書で確かめられなかったので、累積なら置き換え、差分なら足す。
                if (chunk.startsWith(content)) {
                    content.setLength(0)
                    content.append(chunk)
                } else {
                    content.append(chunk)
                }
                onPartial(LlmSnapshot(content.toString()))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: GenAiException) {
            throw LlmException(message(e), cause = e)
        }
        return LlmSnapshot(content.toString())
    }

    private fun message(e: GenAiException): String = when (e.errorCode) {
        GenAiException.ErrorCode.BUSY -> "Gemini Nano が混み合っています。少し待ってからもう一度送ってください。"
        GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> "Gemini Nano はアプリが前面にあるときだけ使えます。"
        GenAiException.ErrorCode.REQUEST_TOO_LARGE -> "入力が長すぎて Gemini Nano では扱えません (およそ 4000 トークンまで)。"
        GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> "Gemini Nano のモデルを置く空き容量が足りません。"
        GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> "Gemini Nano の利用上限に達しました。しばらく待ってください。"
        else -> "Gemini Nano のエラー (${e.errorCode}): ${e.message}"
    }
}
