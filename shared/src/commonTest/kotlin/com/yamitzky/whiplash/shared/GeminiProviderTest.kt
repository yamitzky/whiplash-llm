package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmImage
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.gemini.GeminiProvider
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 実際のサーバーへは送らず、Ktor の MockEngine に SSE を返させて確かめる。 */
class GeminiProviderTest {
    private val sseHeaders = headersOf(HttpHeaders.ContentType, "text/event-stream")

    private fun request(
        endpoint: String = BackendProvider.Gemini.defaultEndpoint,
        apiKey: String? = "AIza-test",
        thinking: ThinkingConfig = ThinkingConfig.Off,
        instructions: String = "あなたは翻訳者です。",
        images: List<LlmImage> = emptyList(),
        prompt: String = "こんにちは",
    ) = LlmRequest(
        model = ModelConfig(name = "m", provider = BackendProvider.Gemini, modelIdentifier = "gemini-2.5-flash", thinking = thinking),
        endpoint = endpoint,
        apiKey = apiKey,
        instructions = instructions,
        prompt = prompt,
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

    /** 本物と同じく CRLF の空行でイベントを区切る。 */
    private fun sse(vararg events: String): String = events.joinToString("") { "data: $it\r\n\r\n" }

    /** [parts] は (text, thought) の組。 */
    private fun chunk(vararg parts: Pair<String, Boolean>): String {
        val json = parts.joinToString(",") { (text, thought) ->
            if (thought) """{"text":${JsonPrimitive(text)},"thought":true}""" else """{"text":${JsonPrimitive(text)}}"""
        }
        return """{"candidates":[{"content":{"parts":[$json],"role":"model"},"index":0}],"modelVersion":"gemini-2.5-flash"}"""
    }

    private fun text(text: String) = chunk(text to false)

    private fun provider(handler: suspend (HttpRequestData) -> Pair<HttpStatusCode, Any>): Pair<GeminiProvider, MutableList<HttpRequestData>> {
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
        return GeminiProvider(HttpClient(engine)) to seen
    }

    private fun HttpRequestData.jsonBody(): JsonObject = Json.parseToJsonElement((body as TextContent).text).jsonObject

    // MARK: - 送る内容

    @Test
    fun 本文はuserのpartsでロールの指示はsystemInstructionで送りAPIキーはヘッダーに付ける() = runTest {
        val (provider, seen) = provider { HttpStatusCode.OK to streamingBody(listOf(sse(text("Hi")).encodeToByteArray())) }

        provider.streamResponse(request()) {}

        val sent = seen.single()
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
            sent.url.toString(),
        )
        assertEquals("AIza-test", sent.headers["x-goog-api-key"])
        assertNull(sent.url.parameters["key"])
        val body = sent.jsonBody()
        val contents = body["contents"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("user"), contents.map { it["role"]!!.jsonPrimitive.content })
        assertEquals("こんにちは", contents[0]["parts"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
        val system = body["systemInstruction"]!!.jsonObject["parts"]!!.jsonArray.single().jsonObject
        assertEquals("あなたは翻訳者です。", system["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun 指示が空ならsystemInstructionを送らない() {
        assertNull(GeminiProvider.requestBody(request(instructions = ""))["systemInstruction"])
    }

    @Test
    fun 接続先の末尾のスラッシュやv1betaの有無によらず同じURLに送る() {
        val expected = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse"
        assertEquals(expected, GeminiProvider.streamGenerateContentUrl("https://generativelanguage.googleapis.com/", "gemini-2.5-pro"))
        assertEquals(expected, GeminiProvider.streamGenerateContentUrl("https://generativelanguage.googleapis.com", "gemini-2.5-pro"))
        assertEquals(expected, GeminiProvider.streamGenerateContentUrl("https://generativelanguage.googleapis.com/v1beta/", "gemini-2.5-pro"))
    }

    @Test
    fun 思考の設定はswiftと同じthinkingConfigで送る() {
        fun config(thinking: ThinkingConfig) =
            GeminiProvider.requestBody(request(thinking = thinking))["generationConfig"]!!.jsonObject["thinkingConfig"]!!.jsonObject

        assertEquals(mapOf("includeThoughts" to "false"), config(ThinkingConfig.Off).mapValues { it.value.jsonPrimitive.content })
        assertEquals(
            mapOf("includeThoughts" to "true", "thinkingBudget" to "-1"),
            config(ThinkingConfig.Auto).mapValues { it.value.jsonPrimitive.content },
        )
        assertEquals(
            mapOf("includeThoughts" to "true", "thinkingBudget" to "2048"),
            config(ThinkingConfig.Budget(2048)).mapValues { it.value.jsonPrimitive.content },
        )
    }

    @Test
    fun 画像はinline_dataの部品として本文より前に送る() {
        val body = GeminiProvider.requestBody(request(images = listOf(LlmImage(byteArrayOf(1, 2, 3), "image/png"))))
        val parts = body["contents"]!!.jsonArray.single().jsonObject["parts"]!!.jsonArray.map { it.jsonObject }
        val inline = parts[0]["inline_data"]!!.jsonObject
        assertEquals("image/png", inline["mime_type"]!!.jsonPrimitive.content)
        assertEquals("AQID", inline["data"]!!.jsonPrimitive.content)
        assertEquals("こんにちは", parts[1]["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun 画像だけで本文が空なら空のtextの部品を付けない() {
        val body = GeminiProvider.requestBody(request(images = listOf(LlmImage(byteArrayOf(1, 2, 3), "image/png")), prompt = ""))
        val parts = body["contents"]!!.jsonArray.single().jsonObject["parts"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf(setOf("inline_data")), parts.map { it.keys })
    }

    // MARK: - 受け取り

    @Test
    fun 行やUTF8の文字の途中で切れて届いても足し合わせて途中経過を渡す() = runTest {
        val bytes = sse(text("こんにちは"), text("、世界")).encodeToByteArray()
        // 「こ」(3 バイト) の 2 バイト目で切り、2 件目のイベントは "data:" の途中で切る。
        val firstCut = bytes.indexOfFirst { it == 0xE3.toByte() } + 1
        val secondCut = sse(text("こんにちは")).encodeToByteArray().size + 3
        val pieces = listOf(bytes.copyOfRange(0, firstCut), bytes.copyOfRange(firstCut, secondCut), bytes.copyOfRange(secondCut, bytes.size))
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(pieces) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }

        assertEquals(listOf("こんにちは", "こんにちは、世界"), partials)
        assertEquals(LlmSnapshot("こんにちは、世界"), last)
    }

    @Test
    fun thoughtの付いたpartはreasoningにそれ以外はcontentに分ける() = runTest {
        val body = sse(
            chunk("考え" to true),
            chunk("中" to true, "答" to false),
            // 署名だけの part と、本文の無い最後のチャンク (finishReason と usage だけ) は途中経過にしない。
            """{"candidates":[{"content":{"parts":[{"thoughtSignature":"CiQB"}],"role":"model"}}]}""",
            chunk("え" to false),
            """{"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"thoughtsTokenCount":12}}""",
        )
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request(thinking = ThinkingConfig.Auto)) { partials += it.displayText }

        assertEquals(
            listOf("<thinking>考え</thinking>\n\n", "<thinking>考え中</thinking>\n\n答", "<thinking>考え中</thinking>\n\n答え"),
            partials,
        )
        assertEquals(LlmSnapshot("答え", "考え中"), last)
    }

    @Test
    fun 最後の空行が無いまま切れた接続も読む() = runTest {
        val body = "data: ${text("A")}\n\ndata: ${text("B")}"
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        assertEquals("AB", provider.streamResponse(request()) {}.content)
    }

    // MARK: - 失敗

    @Test
    fun HTTPのエラーはステータスとAPIのメッセージを持つLlmExceptionになる() = runTest {
        val (provider, _) = provider {
            HttpStatusCode.BadRequest to """{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"""
        }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertEquals(400, error.statusCode)
        assertEquals("API key not valid. Please pass a valid API key.", error.message)
    }

    @Test
    fun 配列に包まれたHTTPのエラーもメッセージを取り出す() = runTest {
        val (provider, _) = provider {
            HttpStatusCode.NotFound to """[{"error":{"code":404,"message":"models/nope is not found","status":"NOT_FOUND"}}]"""
        }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertEquals(404, error.statusCode)
        assertEquals("models/nope is not found", error.message)
    }

    @Test
    fun ストリームの途中で届いたerrorはLlmExceptionになる() = runTest {
        val body = sse(text("途中まで"), """{"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}""")
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        val partials = mutableListOf<String>()
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) { partials += it.displayText } }
        assertEquals("The model is overloaded.", error.message)
        assertNull(error.statusCode)
        assertEquals(listOf("途中まで"), partials)
    }

    @Test
    fun 入力が安全フィルターで止められたら空の応答にせずLlmExceptionにする() = runTest {
        val body = sse("""{"promptFeedback":{"blockReason":"SAFETY"},"modelVersion":"gemini-2.5-flash"}""")
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertTrue("SAFETY" in error.message.orEmpty())
    }

    @Test
    fun 接続できないときもLlmExceptionになる() = runTest {
        val (provider, _) = provider { throw IllegalStateException("connection refused") }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertTrue("connection refused" in error.message.orEmpty())
        assertNull(error.statusCode)
    }
}
