package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ImageInputMode
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.store.InMemoryKeyValueStore
import com.yamitzky.whiplash.shared.store.InMemorySecretStore
import com.yamitzky.whiplash.shared.store.RoleStore
import com.yamitzky.whiplash.shared.store.SettingsStore
import com.yamitzky.whiplash.shared.store.StoredJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * CLAUDE.md の「保存データの形式を変えるとき」の規則を Kotlin 側でも守っているか確かめる。
 * 未知の値を含む JSON は、Swift が書いた fixture の 1 要素を書き換えて作る。
 */
class StoredFormatRulesTest {
    private fun swiftRoleJson(): JsonObject =
        StoredJson.parse(SwiftFixtures.scenario("roles-edit").before.data("roles"))!!.jsonArray[0].jsonObject

    private fun JsonObject.with(key: String, value: kotlinx.serialization.json.JsonElement) = JsonObject(this + (key to value))

    private fun bytes(element: kotlinx.serialization.json.JsonElement) = StoredJson.encode(element)

    // MARK: - responsePatterns

    @Test
    fun 後から足した応答パターンはresponsePatternsに書かず古いビルドが読める値だけを残す() {
        val role = Role(name = "重ねる", icon = "🪟", systemPrompt = "p", responsePatterns = listOf(ResponsePattern.RichMessage, ResponsePattern.Clipboard, ResponsePattern.Overlay))
        val json = StoredJson.encodeRole(role)

        assertEquals(listOf("richMessage", "clipboard"), json["responsePatterns"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf("overlay"), json["additionalResponsePatterns"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(role, StoredJson.decodeRole(json))
    }

    @Test
    fun 後から足した応答パターンが無ければadditionalResponsePatternsを書かない() {
        val json = StoredJson.encodeRole(Role(name = "n", icon = "i", systemPrompt = "p", responsePatterns = listOf(ResponsePattern.RichMessage)))
        assertFalse("additionalResponsePatterns" in json)
    }

    @Test
    fun 未知の応答パターンがあってもロールは失われず未知の値だけ除かれる() {
        val json = swiftRoleJson().with("responsePatterns", buildJsonArray { add(JsonPrimitive("richMessage")); add(JsonPrimitive("fromTheFuture")) })
        val role = StoredJson.decodeRole(json)
        assertEquals(listOf(ResponsePattern.RichMessage), role.responsePatterns)
    }

    @Test
    fun 旧形式のresponsePatternsにあるoverlayも読める() {
        val json = swiftRoleJson().with("responsePatterns", buildJsonArray { add(JsonPrimitive("richMessage")); add(JsonPrimitive("overlay")) })
        assertEquals(listOf(ResponsePattern.RichMessage, ResponsePattern.Overlay), StoredJson.decodeRole(json).responsePatterns)
    }

    @Test
    fun 未知の画像入力方式は既定に戻りロールは失われない() {
        val json = swiftRoleJson().with("imageInputMode", JsonPrimitive("hologram"))
        assertEquals(ImageInputMode.Image, StoredJson.decodeRole(json).imageInputMode)
    }

    @Test
    fun 小文字のUUIDはswiftと同じく大文字で書き戻す() {
        val lower = "5f0b7c9e-2d41-4a8b-9c63-7e1d2a4b8f10"
        val role = StoredJson.decodeRole(swiftRoleJson().with("id", JsonPrimitive(lower)))
        assertEquals(lower.uppercase(), role.id)
    }

    // MARK: - RoleStore

    @Test
    fun 読めないロールが1件でもあれば上書きせず原本を残しプリセットで始める() {
        val original = SwiftFixtures.scenario("roles-edit").before.data("roles")
        val array = StoredJson.parse(original)!!.jsonArray
        val broken = bytes(JsonArray(array + JsonObject(array[0].jsonObject - "name")))
        val defaults = InMemoryKeyValueStore().apply {
            setData("roles", broken)
            setInt("rolesSchemaVersion", 4)
        }

        val store = RoleStore(defaults, addsTranscriptionRole = true, nowEpochSeconds = { 1_700_000_000 })

        assertEquals((RoleStore.presets + RoleStore.transcriptionRole).map { it.name }, store.roles.map { it.name })
        assertContentEquals(broken, defaults.getData("roles"))
        assertContentEquals(broken, defaults.getData("roles.unreadable.1700000000"))
    }

    @Test
    fun 移行は一度だけで原本のバックアップを上書きしない() {
        val original = SwiftFixtures.scenario("roles-migrate-v0").before.data("roles")
        val defaults = InMemoryKeyValueStore().apply { setData("roles", original) }
        RoleStore(defaults, addsTranscriptionRole = true)
        val firstBackup = defaults.getData("roles.backup.v0")!!

        // 古いビルドが schemaVersion を書かずに上書きした状態から、もう一度移行する。
        defaults.values.remove("rolesSchemaVersion")
        defaults.setData("roles", StoredJson.encodeRoles(emptyList()))
        RoleStore(defaults, addsTranscriptionRole = true)

        assertContentEquals(firstBackup, defaults.getData("roles.backup.v0"))
        assertEquals(RoleStore.SCHEMA_VERSION, defaults.getInt("rolesSchemaVersion"))
    }

    @Test
    fun 文字起こしロールを足さない設定なら移行でも足さない() {
        val defaults = SwiftFixtures.scenario("roles-migrate-v0").before.toStore()
        val store = RoleStore(defaults, addsTranscriptionRole = false)
        assertTrue(store.roles.none { it.id == RoleStore.transcriptionRole.id })
    }

    // MARK: - SettingsStore

    @Test
    fun 読めないモデル一覧は上書きせず原本を一度だけ退避し既定のモデルで始める() {
        val broken = "not json".encodeToByteArray()
        val defaults = InMemoryKeyValueStore().apply { setData("models_v2", broken) }
        var now = 100L

        val settings = SettingsStore(defaults, InMemorySecretStore(), nowEpochSeconds = { now })
        assertEquals(ModelConfig.builtinDefaults.size, settings.models.size)
        // 関係のない設定を変えても、読めなかったモデル一覧は書き換えない。
        settings.setEndpoint("http://localhost:9999", BackendProvider.Ollama)
        settings.enterToSend = true
        assertContentEquals(broken, defaults.getData("models_v2"))

        now = 200L
        SettingsStore(defaults, InMemorySecretStore(), nowEpochSeconds = { now })
        assertEquals(listOf("models_v2.unreadable.100"), defaults.keys().filter { it.startsWith("models_v2.unreadable.") })
    }

    @Test
    fun 読めないconnectionsは平文のAPIキーを除いて退避する() {
        // 鍵と値の交互の配列ではない (要素が奇数個) ので、全体を読めない。
        val connections = StoredJson.parse(SwiftFixtures.scenario("settings-edit").before.data("connections"))!!.jsonArray
        val broken = bytes(JsonArray(connections.dropLast(1)))
        val defaults = InMemoryKeyValueStore().apply { setData("connections", broken) }

        val settings = SettingsStore(defaults, InMemorySecretStore(), nowEpochSeconds = { 1 })

        assertTrue(settings.connections.isEmpty())
        val backup = defaults.getData("connections.unreadable.1")!!.decodeToString()
        assertFalse("sk-plaintext-legacy" in backup, backup)
        assertTrue("future.example" in backup, backup)
        assertContentEquals(broken, defaults.getData("connections"))
    }

    @Test
    fun 最後のモデルを消すとdefaultModelIdにnullを書きnullは既定のモデルとして読む() {
        val defaults = InMemoryKeyValueStore()
        val settings = SettingsStore(defaults, InMemorySecretStore())
        settings.models.toList().forEach { settings.deleteModel(it.id) }
        assertEquals("null", defaults.getData("defaultModelId")!!.decodeToString())

        val reloaded = SettingsStore(defaults, InMemorySecretStore())
        assertNull(reloaded.defaultModelId)
        assertTrue(defaults.keys().none { it.contains(".unreadable.") })
    }

    @Test
    fun 平文のAPIキーはsecretsへ移しconnectionsから消す() {
        val defaults = SwiftFixtures.scenario("settings-edit").before.toStore()
        val secrets = InMemorySecretStore()
        val settings = SettingsStore(defaults, secrets)

        assertEquals("sk-plaintext-legacy", settings.apiKey(BackendProvider.OpenAI))
        assertNull(settings.connection(BackendProvider.OpenAI).apiKey)
        assertFalse("sk-plaintext-legacy" in defaults.getData("connections")!!.decodeToString())
    }
}
