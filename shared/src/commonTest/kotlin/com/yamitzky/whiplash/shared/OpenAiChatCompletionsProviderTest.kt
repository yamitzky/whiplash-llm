package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmImage
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.openai.OpenAiChatCompletionsProvider
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ThinkingConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.close
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 実際のサーバーへは送らず、Ktor の MockEngine に SSE を返させて確かめる。 */
class OpenAiChatCompletionsProviderTest {
    private val sseHeaders = headersOf(HttpHeaders.ContentType, "text/event-stream")

    private fun request(
        provider: BackendProvider = BackendProvider.Ollama,
        endpoint: String = provider.defaultEndpoint,
        apiKey: String? = null,
        thinking: ThinkingConfig = ThinkingConfig.Off,
        instructions: String = "あなたは翻訳者です。",
        images: List<LlmImage> = emptyList(),
    ) = LlmRequest(
        model = ModelConfig(name = "m", provider = provider, modelIdentifier = "llama3.2", thinking = thinking),
        endpoint = endpoint,
        apiKey = apiKey,
        instructions = instructions,
        prompt = "こんにちは",
        images = images,
    )

    /** [pieces] を 1 つずつ別々に書く。行や UTF-8 の 1 文字の途中で届いても読めるかを見るため。 */
    private fun streamingBody(pieces: List<ByteArray>): ByteReadChannel {
        val channel = ByteChannel()
        CoroutineScope(Dispatchers.Default).launch {
            for (piece in pieces) {
                channel.writeFully(piece)
                channel.flush()
                yield()
            }
            channel.close()
        }
        return channel
    }

    private fun sse(vararg events: String): String = events.joinToString("") { "data: $it\n\n" }

    private fun chunk(content: String? = null, reasoningContent: String? = null, reasoning: String? = null): String {
        val delta = buildMap {
            content?.let { put("content", it) }
            reasoningContent?.let { put("reasoning_content", it) }
            reasoning?.let { put("reasoning", it) }
        }.entries.joinToString(",") { "\"${it.key}\":${JsonPrimitive(it.value)}" }
        return """{"id":"c","object":"chat.completion.chunk","choices":[{"index":0,"delta":{$delta},"finish_reason":null}]}"""
    }

    private fun provider(handler: suspend (HttpRequestData) -> Pair<HttpStatusCode, Any>): Pair<OpenAiChatCompletionsProvider, MutableList<HttpRequestData>> {
        val seen = mutableListOf<HttpRequestData>()
        val engine = MockEngine { data ->
            seen += data
            val (status, body) = handler(data)
            when (body) {
                is ByteReadChannel -> respond(body, status, sseHeaders)
                is String -> respond(body, status, headersOf(HttpHeaders.ContentType, "application/json"))
                else -> error("unexpected body")
            }
        }
        return OpenAiChatCompletionsProvider(HttpClient(engine)) to seen
    }

    private fun HttpRequestData.jsonBody(): JsonObject = Json.parseToJsonElement((body as TextContent).text).jsonObject

    // MARK: - 送る内容

    @Test
    fun ロールの指示はsystemで本文はuserで送る() = runTest {
        val (provider, seen) = provider { HttpStatusCode.OK to streamingBody(listOf(sse(chunk("Hi"), "[DONE]").encodeToByteArray())) }

        provider.streamResponse(request()) {}

        val body = seen.single().jsonBody()
        assertEquals("llama3.2", body["model"]!!.jsonPrimitive.content)
        assertEquals("true", body["stream"]!!.jsonPrimitive.content)
        val messages = body["messages"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("system", "user"), messages.map { it["role"]!!.jsonPrimitive.content })
        assertEquals("あなたは翻訳者です。", messages[0]["content"]!!.jsonPrimitive.content)
        assertEquals("こんにちは", messages[1]["content"]!!.jsonPrimitive.content)
        assertNull(body["reasoning_effort"])
    }

    @Test
    fun 指示が空ならsystemを送らない() = runTest {
        val (provider, seen) = provider { HttpStatusCode.OK to streamingBody(listOf(sse("[DONE]").encodeToByteArray())) }
        provider.streamResponse(request(instructions = "")) {}
        assertEquals(listOf("user"), seen.single().jsonBody()["messages"]!!.jsonArray.map { it.jsonObject["role"]!!.jsonPrimitive.content })
    }

    @Test
    fun 接続先の書き方によらずchat_completionsのURLに送りAPIキーはBearerで付ける() = runTest {
        val (provider, seen) = provider { HttpStatusCode.OK to streamingBody(listOf(sse("[DONE]").encodeToByteArray())) }

        provider.streamResponse(request(BackendProvider.Ollama)) {}
        provider.streamResponse(request(BackendProvider.LmStudio, endpoint = "http://192.168.0.10:1234/v1/")) {}
        provider.streamResponse(request(BackendProvider.OpenAI, apiKey = "sk-test")) {}
        provider.streamResponse(request(BackendProvider.OpenResponses, apiKey = "sk-or")) {}

        assertEquals(
            listOf(
                "http://localhost:11434/v1/chat/completions",
                "http://192.168.0.10:1234/v1/chat/completions",
                "https://api.openai.com/v1/chat/completions",
                "https://openrouter.ai/api/v1/chat/completions",
            ),
            seen.map { it.url.toString() },
        )
        assertEquals(listOf(null, null, "Bearer sk-test", "Bearer sk-or"), seen.map { it.headers[HttpHeaders.Authorization] })
    }

    @Test
    fun 思考の設定はswiftと同じ対応でOpenAIにだけreasoning_effortとして送る() {
        fun effort(provider: BackendProvider, thinking: ThinkingConfig) =
            OpenAiChatCompletionsProvider.requestBody(request(provider, thinking = thinking))["reasoning_effort"]?.jsonPrimitive?.content

        assertEquals("medium", effort(BackendProvider.OpenAI, ThinkingConfig.Auto))
        assertEquals("low", effort(BackendProvider.OpenAI, ThinkingConfig.Budget(999)))
        assertEquals("medium", effort(BackendProvider.OpenAI, ThinkingConfig.Budget(1000)))
        assertEquals("high", effort(BackendProvider.OpenResponses, ThinkingConfig.Budget(5000)))
        assertNull(effort(BackendProvider.OpenAI, ThinkingConfig.Off))
        assertNull(effort(BackendProvider.Ollama, ThinkingConfig.Auto))
        assertNull(effort(BackendProvider.LmStudio, ThinkingConfig.Budget(8000)))
    }

    @Test
    fun 画像はdata_URLの部品として本文と一緒に送る() {
        val body = OpenAiChatCompletionsProvider.requestBody(request(images = listOf(LlmImage(byteArrayOf(1, 2, 3), "image/png"))))
        val parts = body["messages"]!!.jsonArray.last().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals("こんにちは", parts[0]["text"]!!.jsonPrimitive.content)
        assertEquals("data:image/png;base64,AQID", parts[1]["image_url"]!!.jsonObject["url"]!!.jsonPrimitive.content)
    }

    // MARK: - 受け取り

    @Test
    fun 行やUTF8の文字の途中で切れて届いても足し合わせて途中経過を渡す() = runTest {
        val bytes = sse(chunk("こんにちは"), chunk("、世界"), "[DONE]").encodeToByteArray()
        // 「こ」(3 バイト) の 2 バイト目で切り、2 件目のイベントは "data:" の途中で切る。
        val firstCut = bytes.indexOfFirst { it == 0xE3.toByte() } + 1
        val secondCut = sse(chunk("こんにちは")).encodeToByteArray().size + 3
        val pieces = listOf(bytes.copyOfRange(0, firstCut), bytes.copyOfRange(firstCut, secondCut), bytes.copyOfRange(secondCut, bytes.size))
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(pieces) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }

        assertEquals(listOf("こんにちは", "こんにちは、世界"), partials)
        assertEquals(LlmSnapshot("こんにちは、世界"), last)
    }

    @Test
    fun thinkingはreasoning_contentでもreasoningでも拾いthinkingタグで包む() = runTest {
        val body = sse(chunk(reasoningContent = "考え"), chunk(reasoning = "中"), chunk("答え"), "[DONE]")
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }

        assertEquals(listOf("<thinking>考え</thinking>\n\n", "<thinking>考え中</thinking>\n\n", "<thinking>考え中</thinking>\n\n答え"), partials)
        assertEquals("<thinking>考え中</thinking>\n\n答え", last.displayText)
    }

    @Test
    fun コメント行と中身の無いdeltaは途中経過として渡さずDONEで終える() = runTest {
        val body = ": OPENROUTER PROCESSING\n\n" +
            sse("""{"choices":[{"index":0,"delta":{"role":"assistant"}}]}""", chunk("A"), "[DONE]", chunk("後ろは読まない"))
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }

        assertEquals(listOf("A"), partials)
        assertEquals("A", last.content)
    }

    @Test
    fun CRLFの改行と最後の空行が無いまま切れた接続も読む() = runTest {
        val body = "data: ${chunk("A")}\r\n\r\ndata: ${chunk("B")}"
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        assertEquals("AB", provider.streamResponse(request()) {}.content)
    }

    @Test
    fun streamを無視してJSONで返すサーバーの応答も読む() = runTest {
        val (provider, _) = provider {
            HttpStatusCode.OK to """{"choices":[{"index":0,"message":{"role":"assistant","content":"まとめて","reasoning_content":"考え"}}]}"""
        }
        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }
        assertEquals(listOf("<thinking>考え</thinking>\n\nまとめて"), partials)
        assertEquals("まとめて", last.content)
    }

    // MARK: - 失敗

    @Test
    fun HTTPのエラーはステータスとサーバーのメッセージを持つLlmExceptionになる() = runTest {
        val (provider, _) = provider { HttpStatusCode.Unauthorized to """{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}""" }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertEquals(401, error.statusCode)
        assertEquals("Incorrect API key provided", error.message)
    }

    @Test
    fun ストリームの途中で届いたerrorはLlmExceptionになる() = runTest {
        val body = sse(chunk("途中まで"), """{"error":{"message":"rate limited","code":429}}""")
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        val partials = mutableListOf<String>()
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) { partials += it.displayText } }
        assertEquals("rate limited", error.message)
        assertEquals(listOf("途中まで"), partials)
    }

    @Test
    fun 接続できないときもLlmExceptionになる() = runTest {
        val (provider, _) = provider { throw IllegalStateException("connection refused") }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertTrue("connection refused" in error.message.orEmpty())
        assertFalse(error.statusCode != null)
    }
}
