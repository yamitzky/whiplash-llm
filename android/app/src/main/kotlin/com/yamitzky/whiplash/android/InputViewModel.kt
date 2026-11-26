package com.yamitzky.whiplash.android

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.yamitzky.whiplash.shared.llm.LlmImage
import com.yamitzky.whiplash.shared.model.ImageInputMode
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** 1 回の生成の表示。再生成とフォローアップは新しい [GenerationResult] を作って差し替える。 */
class GenerationResult(val title: String, val inputSummary: String) {
    var text by mutableStateOf("")
    var isStreaming by mutableStateOf(true)
    var error by mutableStateOf<String?>(null)

    /** `<thinking>` を除いた本文。コピーとフォローアップに使う。 */
    val body: String get() = splitThinking(text).second.trim()
}

/**
 * 入力画面の状態。iOS の InputFlow と同じ流れにしている。
 * - 添付が無いとき、入力欄の文字が本文になる。添付があるとき、入力欄の文字は追加の指示になる。
 * - 「質問する」はロールを使わず、既定のモデルに本文と質問をそのまま送る。
 * - フォローアップは、最初の本文と直前の応答と追加の指示をまとめて、同じロールで送り直す。
 */
class InputViewModel(application: Application) : AndroidViewModel(application) {
    private val container = (application as WhiplashApplication).container
    private val clipboard = application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    val attachments = mutableStateListOf<Attachment>()
    var inputText by mutableStateOf("")
    var followUpText by mutableStateOf("")
    var result by mutableStateOf<GenerationResult?>(null)
        private set
    var notice by mutableStateOf<String?>(null)

    /** Activity が起動時の Intent をこの ViewModel に渡したか。画面の回転では残り、プロセスが終わると消える。 */
    var receivedLaunchIntent = false

    private var nextId = 0L
    private var job: Job? = null
    private var last: Request? = null

    private data class Request(
        val fullText: String,
        val images: List<LlmImage>,
        val role: Role,
        val additionalInstructions: String?,
        val title: String,
        val inputSummary: String,
    )

    /** 外から渡された入力 (文字選択メニュー、共有、タイル) で、新しい入力を始める。 */
    fun handleIntent(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: return
                startNew()
                addText(text)
            }
            Intent.ACTION_SEND -> {
                startNew()
                intent.getStringExtra(Intent.EXTRA_TEXT)?.let(::addText)
                intent.streamUri()?.let { addImages(listOf(it)) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                startNew()
                intent.getStringExtra(Intent.EXTRA_TEXT)?.let(::addText)
                addImages(intent.streamUris())
            }
            ACTION_NEW_INPUT -> startNew()
        }
    }

    fun addText(text: String) {
        if (text.isBlank()) return
        attachments.add(Attachment.Text(nextId++, text))
    }

    fun pasteFromClipboard() {
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(getApplication())?.toString()
        if (text.isNullOrBlank()) {
            notice = "クリップボードにテキストがありません"
        } else {
            addText(text)
        }
    }

    fun addImages(uris: List<Uri>) {
        val resolver = getApplication<Application>().contentResolver
        viewModelScope.launch {
            for (uri in uris) {
                try {
                    attachments.add(ImageAttachments.load(resolver, uri, nextId++))
                } catch (e: Exception) {
                    notice = "画像を読み込めませんでした: ${e.message}"
                }
            }
        }
    }

    fun remove(attachment: Attachment) {
        attachments.remove(attachment)
    }

    fun send(role: Role) {
        val instruction = inputText.trim()
        if (attachments.isEmpty() && instruction.isEmpty()) return
        val title = "${role.icon} ${role.name}"
        val summary = inputSummary()
        start(title, summary) {
            val gathered = gather(role.imageInputMode)
            if (attachments.isEmpty()) {
                Request(instruction, emptyList(), role, null, title, summary)
            } else {
                Request(gathered.text, gathered.images, role, instruction.ifEmpty { null }, title, summary)
            }
        }
    }

    fun ask() {
        val question = inputText.trim()
        if (attachments.isEmpty() && question.isEmpty()) return
        val summary = inputSummary()
        start(QUESTION_TITLE, summary) {
            val gathered = gather(ImageInputMode.Image)
            val fullText = listOf(gathered.text, question).filter { it.isNotEmpty() }.joinToString("\n\n---\n")
            Request(fullText, gathered.images, questionRole, null, QUESTION_TITLE, summary)
        }
    }

    fun regenerate() {
        val request = last ?: return
        run(request)
    }

    fun followUp() {
        val request = last ?: return
        val previous = result?.body ?: return
        val text = followUpText.trim()
        if (text.isEmpty()) return
        followUpText = ""
        val context = "${request.fullText}\n\n---\n前回の応答:\n$previous\n\n---\n追加指示: $text"
        // 最初の本文は last に残す。2 回目のフォローアップも、最初の本文と直前の応答から組み立てる (iOS と同じ)。
        run(request.copy(fullText = context, images = emptyList(), additionalInstructions = null, inputSummary = "追加の指示: $text"), keepLast = true)
    }

    fun stop() {
        job?.cancel()
        result?.isStreaming = false
    }

    fun copyResult() {
        val body = result?.body?.takeIf { it.isNotEmpty() } ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText("Whiplash", body))
        // Android 13 からは OS がコピーを知らせるので、重ねて出さない。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) notice = "コピーしました"
    }

    /** 結果を閉じて、空の入力に戻る。 */
    fun startNew() {
        job?.cancel()
        job = null
        result = null
        last = null
        attachments.clear()
        inputText = ""
        followUpText = ""
    }

    private fun start(title: String, summary: String, build: suspend () -> Request) {
        job?.cancel()
        val placeholder = GenerationResult(title, summary)
        result = placeholder
        job = viewModelScope.launch {
            val request = try {
                build()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "preparing input failed", e)
                placeholder.isStreaming = false
                placeholder.error = e.message ?: e.toString()
                return@launch
            }
            last = request
            generate(request, placeholder)
        }
    }

    private fun run(request: Request, keepLast: Boolean = false) {
        job?.cancel()
        val next = GenerationResult(request.title, request.inputSummary)
        result = next
        if (!keepLast) last = request
        job = viewModelScope.launch { generate(request, next) }
    }

    private suspend fun generate(request: Request, into: GenerationResult) {
        try {
            val response = container.llm.generateStreamingResponse(
                fullText = request.fullText,
                role = request.role,
                additionalInstructions = request.additionalInstructions,
                images = request.images,
            ) { into.text = it }
            into.text = response.text
            if (request.role.copiesToClipboard && into === result) copyResult()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 画面には message しか出ないので、原因を追えるようにスタックトレースを logcat に残す。
            Log.w(TAG, "generation failed", e)
            into.error = e.message ?: e.toString()
        } finally {
            into.isStreaming = false
        }
    }

    /** 結果の画面で、何を送ったかを思い出せるようにする短い要約。 */
    private fun inputSummary(): String {
        val texts = attachments.filterIsInstance<Attachment.Text>().map { it.text }
        val imageCount = attachments.count { it is Attachment.Image }
        return buildList {
            if (imageCount > 0) add("画像 $imageCount 枚")
            addAll(texts)
            inputText.trim().takeIf { it.isNotEmpty() }?.let { add(if (attachments.isEmpty()) it else "追加の指示: $it") }
        }.joinToString("\n")
    }

    private class Gathered(val text: String, val images: List<LlmImage>)

    private suspend fun gather(mode: ImageInputMode): Gathered {
        val parts = mutableListOf<String>()
        val images = mutableListOf<LlmImage>()
        for (attachment in attachments.toList()) {
            when (attachment) {
                is Attachment.Text -> parts += attachment.text
                is Attachment.Image -> when (mode) {
                    ImageInputMode.Image -> images += LlmImage(attachment.jpeg, "image/jpeg")
                    ImageInputMode.Ocr -> Ocr.recognize(attachment.bitmap).takeIf { it.isNotBlank() }?.let { parts += it }
                }
            }
        }
        return Gathered(parts.joinToString("\n\n"), images)
    }

    companion object {
        private const val TAG = "Whiplash"
        const val ACTION_NEW_INPUT = "com.yamitzky.whiplash.android.NEW_INPUT"
        private const val QUESTION_TITLE = "⚡ 質問"

        /** WhiplashCore の役割無しの生成と同じく、指示を付けずに既定のモデルへ送る。 */
        private val questionRole = Role(name = "質問", icon = "⚡", systemPrompt = "", responsePatterns = listOf(ResponsePattern.RichMessage))
    }
}

@Suppress("DEPRECATION")
private fun Intent.streamUri(): Uri? =
    if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else getParcelableExtra(Intent.EXTRA_STREAM)

@Suppress("DEPRECATION")
private fun Intent.streamUris(): List<Uri> =
    (if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else getParcelableArrayListExtra(Intent.EXTRA_STREAM))
        ?: emptyList()
