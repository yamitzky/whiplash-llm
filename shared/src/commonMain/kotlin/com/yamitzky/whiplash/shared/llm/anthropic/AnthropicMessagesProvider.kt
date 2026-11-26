package com.yamitzky.whiplash.shared.llm.anthropic

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmProvider
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.SseDecoder
import com.yamitzky.whiplash.shared.llm.openai.OpenAiChatCompletionsProvider
import com.yamitzky.whiplash.shared.model.ThinkingConfig
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readLine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64

/**
 * Anthropic の Messages API (`POST …/v1/messages`, `stream: true`) で生成する。
 *
 * thinking の本文は `content_block_delta` の `thinking_delta` で、本文と同じく生成中に届く。
 */
class AnthropicMessagesProvider(
    private val client: HttpClient = OpenAiChatCompletionsProvider.defaultHttpClient(),
) : LlmProvider {

    @Throws(LlmException::class, CancellationException::class)
    override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
        val url = messagesUrl(request.endpoint)
        val body = requestBody(request).toString()
        try {
            return client.preparePost(url) {
                contentType(ContentType.Application.Json)
                header(HttpHeaders.Accept, "text/event-stream")
                header("x-api-key", request.apiKey.orEmpty())
                header("anthropic-version", API_VERSION)
                setBody(body)
            }.execute { response ->
                if (!response.status.isSuccess()) {
                    val text = response.bodyAsText()
                    throw LlmException(errorMessage(text) ?: "HTTP ${response.status.value}", statusCode = response.status.value)
                }
                readEventStream(response.bodyAsChannel(), onPartial)
            }
        } catch (e: LlmException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw LlmException(e.message ?: e.toString(), cause = e)
        }
    }

    private suspend fun readEventStream(channel: ByteReadChannel, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
        val content = StringBuilder()
        val reasoning = StringBuilder()
        var last = LlmSnapshot("")
        val decoder = SseDecoder()

        // イベント名は `event:` 行にも来るが、data の `type` にも同じものが入るので data だけで分ける。
        fun handle(data: String): Boolean {
            val event = parseJson(data) ?: return true
            when (event.string("type")) {
                "message_stop" -> return false
                "error" -> throw LlmException(event.errorMessage() ?: data)
                "content_block_delta" -> {
                    val delta = event["delta"] as? JsonObject ?: return true
                    val before = content.length + reasoning.length
                    // signature_delta (thinking の署名) や input_json_delta (ツール) は表示しないので捨てる。
                    when (delta.string("type")) {
                        "text_delta" -> delta.string("text")?.let(content::append)
                        "thinking_delta" -> delta.string("thinking")?.let(reasoning::append)
                    }
                    if (content.length + reasoning.length != before) {
                        last = LlmSnapshot(content.toString(), reasoning.toString())
                        onPartial(last)
                    }
                }
            }
            return true
        }

        while (true) {
            val line = channel.readLine() ?: break
            val data = decoder.feed(line) ?: continue
            if (!handle(data)) return last
        }
        decoder.finish()?.let(::handle)
        return last
    }

    companion object {
        const val API_VERSION = "2023-06-01"

        /**
         * thinking を使わないときの max_tokens。Swift (AnyLanguageModel 1.4.1) の既定は 1024 だが、
         * 長い文章の翻訳や要約が途中で切れるため、それより大きくした。
         * 古いモデル (Claude 3 Haiku など) は出力の上限が 4096 で、これを超えると 400 が返る。
         */
        const val MAX_OUTPUT_TOKENS = 8192

        /**
         * 接続先は "https://api.anthropic.com/" と "https://api.anthropic.com/v1" のどちらの形でも書かれうる。
         * 末尾が /v1 なら messages だけを、そうでなければ v1/messages を足す。
         */
        fun messagesUrl(endpoint: String): String {
            val base = endpoint.trimEnd('/')
            return if (base.endsWith("/v1")) "$base/messages" else "$base/v1/messages"
        }

        fun requestBody(request: LlmRequest): JsonObject = buildJsonObject {
            val budget = thinkingBudget(request.model.thinking)
            put("model", request.model.modelIdentifier)
            // API は max_tokens が budget_tokens 以下だと 400 を返す。budget は max_tokens の内数なので、本文の分を上に足す。
            put("max_tokens", MAX_OUTPUT_TOKENS + (budget ?: 0))
            put("stream", true)
            if (request.instructions.isNotEmpty()) put("system", request.instructions)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    if (request.images.isEmpty()) {
                        put("content", request.prompt)
                    } else {
                        put("content", buildJsonArray {
                            // Anthropic の文書は画像を本文より前に置くよう勧めている。Swift は本文を先に送る。
                            for (image in request.images) {
                                add(buildJsonObject {
                                    put("type", "image")
                                    putJsonObject("source") {
                                        put("type", "base64")
                                        put("media_type", image.mimeType)
                                        put("data", Base64.encode(image.data))
                                    }
                                })
                            }
                            // 画像だけを送るときは本文が空になる。Anthropic は空の text ブロックを受け付けないので付けない。
                            if (request.prompt.isNotEmpty()) {
                                add(buildJsonObject {
                                    put("type", "text")
                                    put("text", request.prompt)
                                })
                            }
                        })
                    }
                })
            })
            budget?.let {
                putJsonObject("thinking") {
                    put("type", "enabled")
                    put("budget_tokens", it)
                }
            }
        }

        /**
         * Swift の LLMService.buildOptions と同じ対応。Auto は 4096 で固定している。
         * 1024 未満は API が受けないが、利用者の設定をそのまま送ってエラーで知らせる。
         */
        fun thinkingBudget(thinking: ThinkingConfig): Int? = when (thinking) {
            ThinkingConfig.Off -> null
            ThinkingConfig.Auto -> 4096
            is ThinkingConfig.Budget -> thinking.tokens
        }

        internal fun errorMessage(text: String): String? = parseJson(text)?.errorMessage()

        private fun parseJson(text: String): JsonObject? =
            runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()

        /** 失敗の形は HTTP の本文でもストリーム中でも `{"type":"error","error":{"type":…,"message":…}}`。 */
        private fun JsonObject.errorMessage(): String? {
            val error = this["error"] ?: return null
            return ((error as? JsonObject)?.string("message")) ?: (error as? JsonPrimitive)?.content ?: error.toString()
        }

        private fun JsonObject.string(key: String): String? {
            val value: JsonElement = this[key] ?: return null
            return (value as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
    }
}
