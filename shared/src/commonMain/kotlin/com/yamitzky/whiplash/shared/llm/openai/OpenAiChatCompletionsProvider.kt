package com.yamitzky.whiplash.shared.llm.openai

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmProvider
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.SseDecoder
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ThinkingConfig
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
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
 * OpenAI 互換の Chat Completions API (`POST …/v1/chat/completions`, `stream: true`) で生成する。
 * Ollama、LM Studio、OpenAI、OpenRouter はどれもこの形を受けるので、この 1 つで届く。
 *
 * thinking の本文は `delta.reasoning_content` (LM Studio、DeepSeek など) と
 * `delta.reasoning` (OpenRouter、Ollama) のどちらかで届くので、両方を拾う。
 */
class OpenAiChatCompletionsProvider(
    private val client: HttpClient = defaultHttpClient(),
) : LlmProvider {

    @Throws(LlmException::class, CancellationException::class)
    override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
        val url = chatCompletionsUrl(request.endpoint)
        val body = requestBody(request).toString()
        try {
            return client.preparePost(url) {
                contentType(ContentType.Application.Json)
                header(HttpHeaders.Accept, "text/event-stream")
                request.apiKey?.takeIf { it.isNotBlank() }?.let { header(HttpHeaders.Authorization, "Bearer $it") }
                setBody(body)
            }.execute { response ->
                if (!response.status.isSuccess()) {
                    val text = response.bodyAsText()
                    throw LlmException(errorMessage(text) ?: "HTTP ${response.status.value}", statusCode = response.status.value)
                }
                // stream を無視して JSON をまとめて返すサーバーもある。
                if (response.contentType()?.match(ContentType.Application.Json) == true) {
                    val snapshot = parseCompletion(response.bodyAsText())
                    onPartial(snapshot)
                    return@execute snapshot
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

    private suspend fun readEventStream(
        channel: io.ktor.utils.io.ByteReadChannel,
        onPartial: (LlmSnapshot) -> Unit,
    ): LlmSnapshot {
        val content = StringBuilder()
        val reasoning = StringBuilder()
        var last = LlmSnapshot("")
        val decoder = SseDecoder()

        fun handle(data: String): Boolean {
            if (data == "[DONE]") return false
            val chunk = parseJson(data) ?: return true
            chunk.errorMessage()?.let { throw LlmException(it) }
            val delta = chunk.firstChoice()?.get("delta") as? JsonObject ?: return true
            val before = content.length + reasoning.length
            delta.string("reasoning_content")?.let(reasoning::append)
            delta.string("reasoning")?.let(reasoning::append)
            delta.string("content")?.let(content::append)
            if (content.length + reasoning.length != before) {
                last = LlmSnapshot(content.toString(), reasoning.toString())
                onPartial(last)
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
        /** thinking や長い生成ではサーバーが無通信になる。Swift の LLMService.httpSession と同じく 300 秒待つ。 */
        fun defaultHttpClient(): HttpClient = HttpClient {
            install(HttpTimeout) {
                connectTimeoutMillis = 30_000
                socketTimeoutMillis = 300_000
                requestTimeoutMillis = 600_000
            }
        }

        /**
         * 接続先は "http://localhost:11434" と "https://api.openai.com/v1/" のどちらの形でも書かれうる。
         * 末尾が /v1 なら chat/completions だけを、そうでなければ v1/chat/completions を足す。
         */
        fun chatCompletionsUrl(endpoint: String): String {
            val base = endpoint.trimEnd('/')
            return if (base.endsWith("/v1")) "$base/chat/completions" else "$base/v1/chat/completions"
        }

        fun requestBody(request: LlmRequest): JsonObject = buildJsonObject {
            put("model", request.model.modelIdentifier)
            put("stream", true)
            put("messages", buildJsonArray {
                if (request.instructions.isNotEmpty()) {
                    add(buildJsonObject {
                        put("role", "system")
                        put("content", request.instructions)
                    })
                }
                add(buildJsonObject {
                    put("role", "user")
                    if (request.images.isEmpty()) {
                        put("content", request.prompt)
                    } else {
                        put("content", buildJsonArray {
                            add(buildJsonObject {
                                put("type", "text")
                                put("text", request.prompt)
                            })
                            for (image in request.images) {
                                add(buildJsonObject {
                                    put("type", "image_url")
                                    putJsonObject("image_url") {
                                        put("url", "data:${image.mimeType};base64,${Base64.encode(image.data)}")
                                    }
                                })
                            }
                        })
                    }
                })
            })
            reasoningEffort(request)?.let { put("reasoning_effort", it) }
        }

        /**
         * Swift の LLMService.buildOptions と同じ対応。OpenAI と Open Responses にだけ送る。
         * Ollama と LM Studio は、送らずにモデルとサーバーの既定に任せている。
         */
        fun reasoningEffort(request: LlmRequest): String? {
            if (request.model.provider != BackendProvider.OpenAI && request.model.provider != BackendProvider.OpenResponses) return null
            return when (val thinking = request.model.thinking) {
                ThinkingConfig.Off -> null
                ThinkingConfig.Auto -> "medium"
                is ThinkingConfig.Budget -> when {
                    thinking.tokens < 1000 -> "low"
                    thinking.tokens < 5000 -> "medium"
                    else -> "high"
                }
            }
        }

        internal fun parseCompletion(text: String): LlmSnapshot {
            val root = parseJson(text) ?: throw LlmException("応答が JSON ではありません")
            root.errorMessage()?.let { throw LlmException(it) }
            val message = root.firstChoice()?.get("message") as? JsonObject
                ?: throw LlmException("応答に choices[0].message がありません")
            val reasoning = (message.string("reasoning_content") ?: "") + (message.string("reasoning") ?: "")
            return LlmSnapshot(message.string("content") ?: "", reasoning)
        }

        internal fun errorMessage(text: String): String? = parseJson(text)?.errorMessage()

        private fun parseJson(text: String): JsonObject? =
            runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()

        private fun JsonObject.errorMessage(): String? {
            val error = this["error"] ?: return null
            return ((error as? JsonObject)?.string("message")) ?: (error as? JsonPrimitive)?.content ?: error.toString()
        }

        private fun JsonObject.firstChoice(): JsonObject? =
            (this["choices"] as? kotlinx.serialization.json.JsonArray)?.firstOrNull() as? JsonObject

        private fun JsonObject.string(key: String): String? {
            val value: JsonElement = this[key] ?: return null
            return (value as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
    }
}
