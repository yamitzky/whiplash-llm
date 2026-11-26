package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.model.ThinkingConfig
import com.yamitzky.whiplash.shared.store.InMemoryKeyValueStore
import com.yamitzky.whiplash.shared.store.InMemorySecretStore
import com.yamitzky.whiplash.shared.store.PreservingArray
import com.yamitzky.whiplash.shared.store.PreservingConnections
import com.yamitzky.whiplash.shared.store.RoleStore
import com.yamitzky.whiplash.shared.store.SettingsStore
import com.yamitzky.whiplash.shared.store.StoredJson
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Swift の RoleStore と SettingsStore が書いた fixture を Kotlin で読み、Swift と同じ操作をして、
 * Swift が書いたのと同じ内容になるかを確かめる。操作の手順は
 * WhiplashCore/Tests/WhiplashCoreTests/SharedCoreFixtureExport.swift と同じ順に書いている。
 */
class SwiftFixtureReplayTest {
    private fun uuid(n: Int): String = "36557CE8-0000-4000-8000-" + n.toString().padStart(12, '0')

    // MARK: - そのまま読んで書き戻す

    @Test
    fun swiftが書いた値はどれも読んで書き戻すと同じ内容になる() {
        var checked = 0
        for (scenario in SwiftFixtures.scenarios.values) {
            for (snapshot in listOf(scenario.before, scenario.after)) {
                for ((name, bytes) in snapshot.files) {
                    val key = name.substringBeforeLast('.')
                    val rewritten = when {
                        !name.endsWith(".data") -> continue
                        key == "roles" || key.startsWith("roles.backup.") ->
                            StoredJson.encodeRoles(StoredJson.decodeRoles(bytes))
                        key == "models_v2" -> {
                            val loaded = assertNotNull(PreservingArray.decode(bytes, StoredJson::decodeModel), name)
                            PreservingArray.encode(loaded.elements, loaded.unreadable, StoredJson::encodeModel)
                        }
                        key == "connections" -> {
                            val loaded = assertNotNull(PreservingConnections.decode(bytes), name)
                            PreservingConnections.encode(loaded.connections, loaded.unreadable)
                        }
                        key.startsWith("defaultModelId") ->
                            StoredJson.encodeOptionalUuid(StoredJson.decodeOptionalUuid(bytes).getOrThrow())
                        else -> error("読み方を決めていないキー: ${scenario.name}/$name")
                    }
                    // before の connections は、テストが JSONEncoder に辞書のまま書かせたので組の順番が決まらない。
                    assertSameJson(bytes, rewritten, "${scenario.name}/$name", unorderedPairs = key == "connections")
                    checked++
                }
            }
        }
        // fixture が空でも通ってしまわないように。
        assertTrue(checked >= 20, "確かめた値の数: $checked")
    }

    // MARK: - ロール

    @Test
    fun 新規インストールではswiftと同じプリセットと文字起こしロールで始める() {
        val swift = SwiftFixtures.scenario("roles-fresh").after
        val store = InMemoryKeyValueStore()
        val roles = RoleStore(store, addsTranscriptionRole = true).roles

        // プリセットの ID は Swift も Kotlin も起動ごとに作るので、ID 以外を比べる。
        val swiftRoles = StoredJson.decodeRoles(swift.data("roles"))
        assertEquals(swiftRoles.map { it.copy(id = "") }, roles.map { it.copy(id = "") })
        assertEquals(RoleStore.transcriptionRole.id, swiftRoles.last().id)
        assertEquals(4, store.getInt("rolesSchemaVersion"))
    }

    @Test
    fun ロールの編集はswiftと同じ内容で保存される() {
        val scenario = SwiftFixtures.scenario("roles-edit")
        val defaults = scenario.before.toStore()

        val store = RoleStore(defaults, addsTranscriptionRole = true)
        store.update(store.roles[0].withCopiesToClipboard(true))
        val third = store.roles[2]
        store.update(third.copy(responsePatterns = listOf(ResponsePattern.RichMessage), imageInputMode = com.yamitzky.whiplash.shared.model.ImageInputMode.Ocr))
        store.add(Role(id = uuid(5), name = "追加", icon = "➕", systemPrompt = "added", responsePatterns = listOf(ResponsePattern.RichMessage, ResponsePattern.Overlay)))
        store.delete(store.roles[1])
        store.move(fromOffsets = setOf(0), toOffset = 3)

        scenario.after.assertSameContent(defaults)
    }

    @Test
    fun schemaVersionが無い保存データはswiftと同じく原本を残して移行し文字起こしロールを足す() {
        val scenario = SwiftFixtures.scenario("roles-migrate-v0")
        val defaults = scenario.before.toStore()
        RoleStore(defaults, addsTranscriptionRole = true)
        scenario.after.assertSameContent(defaults)
    }

    @Test
    fun 名前を変えた文字起こしロールがあるv3はswiftと同じく足さずに移行する() {
        val scenario = SwiftFixtures.scenario("roles-migrate-v3-renamed")
        val defaults = scenario.before.toStore()
        RoleStore(defaults, addsTranscriptionRole = true)
        scenario.after.assertSameContent(defaults)
    }

    // MARK: - 設定

    @Test
    fun 新規インストールではswiftと同じ既定のモデルを保存する() {
        val swift = SwiftFixtures.scenario("settings-fresh").after
        val defaults = InMemoryKeyValueStore()
        val settings = SettingsStore(defaults, InMemorySecretStore())

        val swiftModels = assertNotNull(PreservingArray.decode(swift.data("models_v2"), StoredJson::decodeModel)).elements
        assertEquals(swiftModels.map { it.copy(id = "") }, settings.models.map { it.copy(id = "") })
        assertEquals(setOf("models_v2", "defaultModelId"), defaults.keys())
        assertEquals(settings.models.first().id, StoredJson.decodeOptionalUuid(defaults.getData("defaultModelId")!!).getOrThrow())
    }

    @Test
    fun 設定の編集はswiftと同じ内容で保存され読めない要素も残る() {
        val scenario = SwiftFixtures.scenario("settings-edit")
        val defaults = scenario.before.toStore()
        val secrets = InMemorySecretStore()

        val settings = SettingsStore(defaults, secrets)
        settings.setEndpoint("http://192.168.0.10:1234/v1", BackendProvider.LmStudio)
        settings.setEndpoint("https://generativelanguage.googleapis.com/", BackendProvider.Gemini)
        settings.setApiKey("sk-or-test", BackendProvider.OpenResponses)
        settings.addModel(ModelConfig(id = uuid(110), name = "追加", provider = BackendProvider.OpenAI, modelIdentifier = "gpt-added", thinking = ThinkingConfig.Budget(500)))
        settings.updateModel(settings.models[0].copy(thinking = ThinkingConfig.Budget(8192), name = "Foundation 改"))
        settings.moveModel(fromOffsets = setOf(2), toOffset = 0)
        settings.deleteModel(uuid(102))
        settings.enterToSend = true

        scenario.after.assertSameContent(defaults)
        assertEquals(scenario.after.secrets, secrets.values)
    }

    @Test
    fun defaultModelIdがnullならswiftと同じモデルを既定にするが退避はしない() {
        val scenario = SwiftFixtures.scenario("settings-null-default")
        val defaults = scenario.before.toStore()

        val settings = SettingsStore(defaults, InMemorySecretStore())

        assertEquals(uuid(101), settings.defaultModelId)
        // Swift は自分で書いた null を読めずに defaultModelId.unreadable.<時刻> へ退避する。Kotlin は退避しない。
        assertTrue(scenario.after.files.keys.any { it.startsWith("defaultModelId.unreadable.") })
        assertTrue(defaults.keys().none { it.startsWith("defaultModelId.unreadable.") })
        scenario.after.assertSameContent(defaults, ignoringKeyPrefixes = listOf("defaultModelId.unreadable."))
    }
}
