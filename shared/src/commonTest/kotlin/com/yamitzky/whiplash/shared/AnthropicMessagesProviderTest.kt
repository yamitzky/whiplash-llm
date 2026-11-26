package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmImage
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.anthropic.AnthropicMessagesProvider
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

/** 実際のサーバーへは送らず、Ktor の MockEngine に SSE を返させて確かめる。 */
class AnthropicMessagesProviderTest {
    private val sseHeaders = headersOf(HttpHeaders.ContentType, "text/event-stream")

    private fun request(
        endpoint: String = BackendProvider.Anthropic.defaultEndpoint,
        apiKey: String? = "sk-ant-test",
        thinking: ThinkingConfig = ThinkingConfig.Off,
        instructions: String = "あなたは翻訳者です。",
        images: List<LlmImage> = emptyList(),
        prompt: String = "こんにちは",
    ) = LlmRequest(
        model = ModelConfig(name = "m", provider = BackendProvider.Anthropic, modelIdentifier = "claude-haiku-4-5", thinking = thinking),
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

    /** 本物と同じく `event:` 行と `data:` 行の組で書く。 */
    private fun sse(vararg events: String): String = events.joinToString("") {
        val type = Json.parseToJsonElement(it).jsonObject["type"]!!.jsonPrimitive.content
        "event: $type\ndata: $it\n\n"
    }

    private fun textDelta(text: String) =
        """{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":${JsonPrimitive(text)}}}"""

    private fun thinkingDelta(text: String) =
        """{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":${JsonPrimitive(text)}}}"""

    private val messageStart = """{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"""
    private val textBlockStart = """{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"""
    private val ping = """{"type":"ping"}"""
    private val messageStop = """{"type":"message_stop"}"""

    private fun provider(handler: suspend (HttpRequestData) -> Pair<HttpStatusCode, Any>): Pair<AnthropicMessagesProvider, MutableList<HttpRequestData>> {
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
        return AnthropicMessagesProvider(HttpClient(engine)) to seen
    }

    private fun HttpRequestData.jsonBody(): JsonObject = Json.parseToJsonElement((body as TextContent).text).jsonObject

    // MARK: - 送る内容

    @Test
    fun ロールの指示はsystemで本文はuserのmessageで送りAPIキーとバージョンをヘッダーに付ける() = runTest {
        val (provider, seen) = provider { HttpStatusCode.OK to streamingBody(listOf(sse(messageStop).encodeToByteArray())) }

        provider.streamResponse(request()) {}

        val sent = seen.single()
        assertEquals("https://api.anthropic.com/v1/messages", sent.url.toString())
        assertEquals("sk-ant-test", sent.headers["x-api-key"])
        assertEquals("2023-06-01", sent.headers["anthropic-version"])
        val body = sent.jsonBody()
        assertEquals("claude-haiku-4-5", body["model"]!!.jsonPrimitive.content)
        assertEquals("true", body["stream"]!!.jsonPrimitive.content)
        assertEquals("8192", body["max_tokens"]!!.jsonPrimitive.content)
        assertEquals("あなたは翻訳者です。", body["system"]!!.jsonPrimitive.content)
        val messages = body["messages"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("user"), messages.map { it["role"]!!.jsonPrimitive.content })
        assertEquals("こんにちは", messages[0]["content"]!!.jsonPrimitive.content)
        assertNull(body["thinking"])
    }

    @Test
    fun 指示が空ならsystemを送らない() {
        assertNull(AnthropicMessagesProvider.requestBody(request(instructions = ""))["system"])
    }

    @Test
    fun 接続先の末尾のスラッシュやv1の有無によらずv1_messagesに送る() {
        assertEquals("https://api.anthropic.com/v1/messages", AnthropicMessagesProvider.messagesUrl("https://api.anthropic.com/"))
        assertEquals("https://api.anthropic.com/v1/messages", AnthropicMessagesProvider.messagesUrl("https://api.anthropic.com"))
        assertEquals("https://proxy.example/v1/messages", AnthropicMessagesProvider.messagesUrl("https://proxy.example/v1/"))
    }

    @Test
    fun 思考の設定はswiftと同じbudget_tokensで送りmax_tokensはその分を上に足す() {
        fun thinking(config: ThinkingConfig) = AnthropicMessagesProvider.requestBody(request(thinking = config))

        val auto = thinking(ThinkingConfig.Auto)
        assertEquals("enabled", auto["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("4096", auto["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content)
        assertEquals("12288", auto["max_tokens"]!!.jsonPrimitive.content)

        val budget = thinking(ThinkingConfig.Budget(20000))
        assertEquals("20000", budget["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content)
        assertEquals("28192", budget["max_tokens"]!!.jsonPrimitive.content)

        assertNull(thinking(ThinkingConfig.Off)["thinking"])
    }

    @Test
    fun 画像はbase64のimageブロックとして本文のtextブロックより前に送る() {
        val body = AnthropicMessagesProvider.requestBody(request(images = listOf(LlmImage(byteArrayOf(1, 2, 3), "image/png"))))
        val blocks = body["messages"]!!.jsonArray.single().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("image", "text"), blocks.map { it["type"]!!.jsonPrimitive.content })
        val source = blocks[0]["source"]!!.jsonObject
        assertEquals("base64", source["type"]!!.jsonPrimitive.content)
        assertEquals("image/png", source["media_type"]!!.jsonPrimitive.content)
        assertEquals("AQID", source["data"]!!.jsonPrimitive.content)
        assertEquals("こんにちは", blocks[1]["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun 画像だけで本文が空なら空のtextブロックを付けない() {
        val body = AnthropicMessagesProvider.requestBody(request(images = listOf(LlmImage(byteArrayOf(1, 2, 3), "image/png")), prompt = ""))
        val blocks = body["messages"]!!.jsonArray.single().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("image"), blocks.map { it["type"]!!.jsonPrimitive.content })
    }

    // MARK: - 受け取り

    @Test
    fun 行やUTF8の文字の途中で切れて届いても足し合わせて途中経過を渡す() = runTest {
        val head = sse(messageStart, textBlockStart, ping)
        val bytes = (head + sse(textDelta("こんにちは"), textDelta("、世界"), messageStop)).encodeToByteArray()
        // 「こ」(3 バイト) の 2 バイト目で切り、2 件目の delta は "event:" の途中で切る。
        val firstCut = bytes.indexOfFirst { it == 0xE3.toByte() } + 1
        val secondCut = (head + sse(textDelta("こんにちは"))).encodeToByteArray().size + 3
        val pieces = listOf(bytes.copyOfRange(0, firstCut), bytes.copyOfRange(firstCut, secondCut), bytes.copyOfRange(secondCut, bytes.size))
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(pieces) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request()) { partials += it.displayText }

        assertEquals(listOf("こんにちは", "こんにちは、世界"), partials)
        assertEquals(LlmSnapshot("こんにちは、世界"), last)
    }

    @Test
    fun thinking_deltaはreasoningにtext_deltaはcontentに分けて署名は捨てる() = runTest {
        val body = sse(
            messageStart,
            """{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}""",
            thinkingDelta("考え"),
            thinkingDelta("中"),
            """{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}""",
            """{"type":"content_block_stop","index":0}""",
            textBlockStart,
            textDelta("答え"),
            """{"type":"content_block_stop","index":1}""",
            """{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}""",
            messageStop,
        )
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }

        val partials = mutableListOf<String>()
        val last = provider.streamResponse(request(thinking = ThinkingConfig.Auto)) { partials += it.displayText }

        assertEquals(listOf("<thinking>考え</thinking>\n\n", "<thinking>考え中</thinking>\n\n", "<thinking>考え中</thinking>\n\n答え"), partials)
        assertEquals(LlmSnapshot("答え", "考え中"), last)
    }

    @Test
    fun message_stopで終えて後ろは読まない() = runTest {
        val body = sse(textDelta("A"), messageStop, textDelta("後ろは読まない"))
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        assertEquals("A", provider.streamResponse(request()) {}.content)
    }

    @Test
    fun CRLFの改行と最後の空行が無いまま切れた接続も読む() = runTest {
        val body = "event: content_block_delta\r\ndata: ${textDelta("A")}\r\n\r\ndata: ${textDelta("B")}"
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        assertEquals("AB", provider.streamResponse(request()) {}.content)
    }

    // MARK: - 失敗

    @Test
    fun HTTPのエラーはステータスとAPIのメッセージを持つLlmExceptionになる() = runTest {
        val (provider, _) = provider {
            HttpStatusCode.Unauthorized to """{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"""
        }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertEquals(401, error.statusCode)
        assertEquals("invalid x-api-key", error.message)
    }

    @Test
    fun ストリームの途中で届いたerrorイベントはLlmExceptionになる() = runTest {
        val body = sse(textDelta("途中まで"), """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""")
        val (provider, _) = provider { HttpStatusCode.OK to streamingBody(listOf(body.encodeToByteArray())) }
        val partials = mutableListOf<String>()
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) { partials += it.displayText } }
        assertEquals("Overloaded", error.message)
        assertNull(error.statusCode)
        assertEquals(listOf("途中まで"), partials)
    }

    @Test
    fun 接続できないときもLlmExceptionになる() = runTest {
        val (provider, _) = provider { throw IllegalStateException("connection refused") }
        val error = assertFailsWith<LlmException> { provider.streamResponse(request()) {} }
        assertEquals(true, "connection refused" in error.message.orEmpty())
        assertNull(error.statusCode)
    }
}
