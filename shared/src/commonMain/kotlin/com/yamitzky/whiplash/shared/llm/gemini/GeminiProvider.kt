package com.yamitzky.whiplash.shared.llm.gemini

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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64

/**
 * Gemini API の `POST …/v1beta/models/{model}:streamGenerateContent?alt=sse` で生成する。
 *
 * thinking は本文ではなく、`thought: true` の付いた part として生成中に届く。
 * 届くのは思考の要約で、`includeThoughts` を true にしたときだけ。
 */
class GeminiProvider(
    private val client: HttpClient = OpenAiChatCompletionsProvider.defaultHttpClient(),
) : LlmProvider {

    @Throws(LlmException::class, CancellationException::class)
    override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
        val url = streamGenerateContentUrl(request.endpoint, request.model.modelIdentifier)
        val body = requestBody(request).toString()
        try {
            return client.preparePost(url) {
                contentType(ContentType.Application.Json)
                header(HttpHeaders.Accept, "text/event-stream")
                // クエリの ?key= ではなくヘッダーで送る。URL はログやエラーに残りやすい。
                header("x-goog-api-key", request.apiKey.orEmpty())
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

        // Gemini は終わりの合図 ([DONE] や message_stop) を送らず、接続を閉じて終える。
        fun handle(data: String) {
            val chunk = parseJson(data) as? JsonObject ?: return
            chunk.errorMessage()?.let { throw LlmException(it) }
            // 入力が安全フィルターで止められると candidates が無いまま終わり、そのままでは空の応答に見える。
            chunk.blockReason()?.let { throw LlmException("Gemini が入力を拒否しました: $it") }
            val parts = chunk.firstCandidate()?.obj("content")?.get("parts") as? JsonArray ?: return
            val before = content.length + reasoning.length
            for (part in parts) {
                val obj = part as? JsonObject ?: continue
                // 本文の無い part (thoughtSignature だけのものなど) は text を持たない。
                val text = obj.string("text") ?: continue
                if ((obj["thought"] as? JsonPrimitive)?.content == "true") reasoning.append(text) else content.append(text)
            }
            if (content.length + reasoning.length != before) {
                last = LlmSnapshot(content.toString(), reasoning.toString())
                onPartial(last)
            }
        }

        while (true) {
            val line = channel.readLine() ?: break
            val data = decoder.feed(line) ?: continue
            handle(data)
        }
        decoder.finish()?.let(::handle)
        return last
    }

    companion object {
        /**
         * 接続先は "https://generativelanguage.googleapis.com/" と "…/v1beta" のどちらの形でも書かれうる。
         * 末尾が /v1beta なら models/… だけを、そうでなければ v1beta/models/… を足す。
         */
        fun streamGenerateContentUrl(endpoint: String, model: String): String {
            val base = endpoint.trimEnd('/')
            val versioned = if (base.endsWith("/v1beta")) base else "$base/v1beta"
            return "$versioned/models/$model:streamGenerateContent?alt=sse"
        }

        fun requestBody(request: LlmRequest): JsonObject = buildJsonObject {
            putJsonArray("contents") {
                add(buildJsonObject {
                    put("role", "user")
                    putJsonArray("parts") {
                        // Gemini の文書は 1 枚の画像なら本文より前に置くよう勧めている。Swift は本文を先に送る。
                        for (image in request.images) {
                            add(buildJsonObject {
                                putJsonObject("inline_data") {
                                    put("mime_type", image.mimeType)
                                    put("data", Base64.encode(image.data))
                                }
                            })
                        }
                        // 画像だけを送るときは本文が空になる。空の text の part は送らない。
                        if (request.prompt.isNotEmpty() || request.images.isEmpty()) add(buildJsonObject { put("text", request.prompt) })
                    }
                })
            }
            if (request.instructions.isNotEmpty()) {
                putJsonObject("systemInstruction") {
                    putJsonArray("parts") { add(buildJsonObject { put("text", request.instructions) }) }
                }
            }
            putJsonObject("generationConfig") {
                put("thinkingConfig", thinkingConfig(request.model.thinking))
            }
        }

        /**
         * Swift (LLMService.buildOptions と AnyLanguageModel 1.4.1 の GeminiLanguageModel) が送るものと同じ。
         * Off は includeThoughts を false にするだけで thinkingBudget を送らない。
         * 2.5 Pro のように thinking を切れないモデルがあり、0 を送るとそれらが 400 を返すため。
         * そのため Off でもモデルは裏で考えうるが、要約は届かない。
         */
        fun thinkingConfig(thinking: ThinkingConfig): JsonObject = buildJsonObject {
            when (thinking) {
                ThinkingConfig.Off -> put("includeThoughts", false)
                ThinkingConfig.Auto -> {
                    put("includeThoughts", true)
                    // -1 はモデルに量を任せる (dynamic thinking)。
                    put("thinkingBudget", -1)
                }
                is ThinkingConfig.Budget -> {
                    put("includeThoughts", true)
                    put("thinkingBudget", thinking.tokens)
                }
            }
        }

        internal fun errorMessage(text: String): String? = when (val root = parseJson(text)) {
            is JsonObject -> root.errorMessage()
            // streamGenerateContent は失敗を配列に包んで返すことがある。
            is JsonArray -> (root.firstOrNull() as? JsonObject)?.errorMessage()
            else -> null
        }

        private fun parseJson(text: String): JsonElement? = runCatching { Json.parseToJsonElement(text) }.getOrNull()

        /** 失敗の形は `{"error":{"code":400,"message":…,"status":"INVALID_ARGUMENT"}}`。 */
        private fun JsonObject.errorMessage(): String? {
            val error = this["error"] ?: return null
            return ((error as? JsonObject)?.string("message")) ?: (error as? JsonPrimitive)?.content ?: error.toString()
        }

        private fun JsonObject.blockReason(): String? = obj("promptFeedback")?.string("blockReason")

        private fun JsonObject.firstCandidate(): JsonObject? = (this["candidates"] as? JsonArray)?.firstOrNull() as? JsonObject

        private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

        private fun JsonObject.string(key: String): String? {
            val value: JsonElement = this[key] ?: return null
            return (value as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
    }
}
