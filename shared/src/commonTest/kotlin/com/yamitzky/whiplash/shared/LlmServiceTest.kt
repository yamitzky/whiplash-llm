package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.llm.LlmException
import com.yamitzky.whiplash.shared.llm.LlmProvider
import com.yamitzky.whiplash.shared.llm.LlmRequest
import com.yamitzky.whiplash.shared.llm.LlmResponse
import com.yamitzky.whiplash.shared.llm.LlmService
import com.yamitzky.whiplash.shared.llm.LlmSnapshot
import com.yamitzky.whiplash.shared.llm.Prompt
import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.store.InMemoryKeyValueStore
import com.yamitzky.whiplash.shared.store.InMemorySecretStore
import com.yamitzky.whiplash.shared.store.SettingsStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LlmServiceTest {
    /** runTest の仮想時間では、別スレッドの完了を待つ前に withTimeout が切れるので、実時間で待つ。 */
    private suspend fun <T> realTime(block: suspend () -> T): T =
        withContext(Dispatchers.Default) { withTimeout(5_000) { block() } }

    private val local = ModelConfig(name = "Local", provider = BackendProvider.Ollama, modelIdentifier = "llama3.2")
    private val remote = ModelConfig(name = "Remote", provider = BackendProvider.OpenAI, modelIdentifier = "gpt-x")

    private fun settings(): SettingsStore {
        val settings = SettingsStore(InMemoryKeyValueStore(), InMemorySecretStore())
        settings.models.toList().forEach { settings.deleteModel(it.id) }
        settings.addModel(local)
        settings.addModel(remote)
        settings.setEndpoint("http://192.168.0.20:11434", BackendProvider.Ollama)
        settings.setApiKey("sk-test", BackendProvider.OpenAI)
        return settings
    }

    private fun role(modelId: String?) = Role(name = "英訳", icon = "🌐", systemPrompt = "Translate.", responsePatterns = listOf(ResponsePattern.RichMessage), modelId = modelId)

    private class RecordingProvider(private val snapshots: List<LlmSnapshot>) : LlmProvider {
        val requests = mutableListOf<LlmRequest>()
        override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
            requests += request
            snapshots.forEach(onPartial)
            return snapshots.last()
        }
    }

    @Test
    fun ロールが選んだモデルの接続先とAPIキーと指示で依頼を組み立てる() {
        val service = LlmService(settings(), providerFor = { null })

        val toRemote = service.buildRequest("本文", role(remote.id), additionalInstructions = "短く")
        assertEquals(remote, toRemote.model)
        assertEquals("https://api.openai.com/v1/", toRemote.endpoint)
        assertEquals("sk-test", toRemote.apiKey)
        assertEquals("Translate.", toRemote.instructions)
        assertEquals("本文\n\n---\n追加指示: 短く", toRemote.prompt)

        // モデルを選んでいないロールと、消えたモデルを選んでいるロールは既定のモデルを使う。
        val toDefault = service.buildRequest("本文", role(null))
        assertEquals(local, toDefault.model)
        assertEquals("http://192.168.0.20:11434", toDefault.endpoint)
        assertNull(toDefault.apiKey)
        assertEquals("本文", toDefault.prompt)
        assertEquals(local, service.buildRequest("本文", role("00000000-0000-0000-0000-000000000000")).model)
    }

    @Test
    fun 途中経過と結果はthinkingタグを含む表示用の文字列で渡す() = runTest {
        val provider = RecordingProvider(listOf(LlmSnapshot("", "考え"), LlmSnapshot("答え", "考え")))
        val service = LlmService(settings(), providerFor = { provider })

        val partials = mutableListOf<String>()
        val response = service.generateStreamingResponse("本文", role(local.id)) { partials += it }

        assertEquals(listOf("<thinking>考え</thinking>\n\n", "<thinking>考え</thinking>\n\n答え"), partials)
        assertEquals(LlmResponse("<thinking>考え</thinking>\n\n答え"), response)
        assertEquals(BackendProvider.Ollama, provider.requests.single().model.provider)
    }

    @Test
    fun この端末で使えないプロバイダーのモデルは理由を添えて失敗する() = runTest {
        val service = LlmService(settings(), providerFor = { null })
        val error = assertFailsWith<LlmException> { service.generateStreamingResponse("本文", role(local.id)) {} }
        assertTrue("Ollama" in error.message.orEmpty())
    }

    @Test
    fun コールバック版は結果を完了のコールバックで渡す() = runTest {
        val service = LlmService(settings(), providerFor = { RecordingProvider(listOf(LlmSnapshot("答え"))) })
        val done = CompletableDeferred<Pair<LlmResponse?, Throwable?>>()

        service.startStreamingResponse("本文", role(null), null, emptyList(), onPartialResponse = {}) { response, error ->
            done.complete(response to error)
        }

        assertEquals(LlmResponse("答え") to null, realTime { done.await() })
    }

    @Test
    fun コールバック版はキャンセルするとプロバイダーの処理を止める() = runTest {
        val started = CompletableDeferred<Unit>()
        val stopped = CompletableDeferred<Unit>()
        val provider = object : LlmProvider {
            override suspend fun streamResponse(request: LlmRequest, onPartial: (LlmSnapshot) -> Unit): LlmSnapshot {
                started.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    stopped.complete(Unit)
                }
            }
        }
        val service = LlmService(settings(), providerFor = { provider })
        var completed = false

        val cancellation = service.startStreamingResponse("本文", role(null), null, emptyList(), onPartialResponse = {}) { _, _ -> completed = true }
        realTime { started.await() }
        cancellation.cancel()
        realTime { stopped.await() }

        assertEquals(false, completed)
    }

    @Test
    fun 追加指示が空なら本文だけを送る() {
        assertEquals("本文", Prompt.build("本文", ""))
        assertEquals("本文", Prompt.build("本文", null))
    }

    @Test
    fun thinkingが無ければ本文だけを表示し複数あれば空行でつなぐ() {
        assertEquals("答え", Prompt.displayText("答え", listOf("")))
        assertEquals("<thinking>一\n\n二</thinking>\n\n答え", Prompt.displayText("答え", listOf("一", "", "二")))
    }
}
