package com.yamitzky.whiplash.shared

import com.yamitzky.whiplash.shared.store.InMemoryKeyValueStore
import com.yamitzky.whiplash.shared.store.StoredJson
import kotlin.io.encoding.Base64
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.fail

/**
 * WhiplashCore の SharedCoreFixtureExport が書き出した UserDefaults の中身 1 回分。
 * ファイル名は `<キー>.data` (Data)、`<キー>.int`、`<キー>.bool`。secrets.json は SecretStore の中身。
 */
class FixtureSnapshot(val files: Map<String, ByteArray>) {
    fun data(key: String): ByteArray = files["$key.data"] ?: fail("fixture に $key.data が無い: ${files.keys}")

    val secrets: Map<String, String>
        get() {
            val json = files["secrets.json"] ?: return emptyMap()
            val obj = StoredJson.parse(json) as kotlinx.serialization.json.JsonObject
            return obj.mapValues { (it.value as kotlinx.serialization.json.JsonPrimitive).content }
        }

    /** Swift が書いたのと同じ値を、空の保存先に入れて返す。 */
    fun toStore(): InMemoryKeyValueStore {
        val store = InMemoryKeyValueStore()
        for ((name, bytes) in files) {
            val key = name.substringBeforeLast('.')
            when (name.substringAfterLast('.')) {
                "data" -> store.setData(key, bytes)
                "int" -> store.setInt(key, bytes.decodeToString().toInt())
                "bool" -> store.setBool(key, bytes.decodeToString().toBooleanStrict())
            }
        }
        return store
    }

    /**
     * [actual] の中身が、このスナップショットと同じ内容か確かめる。
     * Data は JSON として比べる。Swift の JSONEncoder はキーの順番を決めず `/` を `\/` と書くが、
     * 読む側にとっては同じ値なので、バイト列の一致までは求めない。
     */
    fun assertSameContent(actual: InMemoryKeyValueStore, ignoringKeyPrefixes: List<String> = emptyList()) {
        fun ignored(key: String) = ignoringKeyPrefixes.any { key.startsWith(it) }
        val expectedKeys = files.keys.filter { it != "secrets.json" }.map { it.substringBeforeLast('.') }.filterNot(::ignored).toSet()
        assertEquals(expectedKeys, actual.keys().filterNot(::ignored).toSet(), "保存されたキー")
        for ((name, bytes) in files) {
            val key = name.substringBeforeLast('.')
            if (name == "secrets.json" || ignored(key)) continue
            when (name.substringAfterLast('.')) {
                "data" -> assertSameJson(bytes, assertNotNull(actual.getData(key)), key)
                "int" -> assertEquals(bytes.decodeToString().toInt(), actual.getInt(key), key)
                "bool" -> assertEquals(bytes.decodeToString().toBooleanStrict(), actual.getBool(key), key)
            }
        }
    }
}

class FixtureScenario(val name: String, val before: FixtureSnapshot, val after: FixtureSnapshot)

object SwiftFixtures {
    val scenarios: Map<String, FixtureScenario> by lazy {
        val byScenario = swiftFixtureFiles.entries.groupBy { it.key.substringBefore('/') }
        byScenario.mapValues { (name, entries) ->
            fun phase(phase: String) = FixtureSnapshot(
                entries.filter { it.key.split('/')[1] == phase }
                    .associate { it.key.substringAfterLast('/') to Base64.decode(it.value) },
            )
            FixtureScenario(name, phase("before"), phase("after"))
        }
    }

    fun scenario(name: String): FixtureScenario = scenarios[name] ?: fail("fixture のシナリオ $name が無い: ${scenarios.keys}")
}

/**
 * 同じ JSON の値か確かめる。
 * [unorderedPairs] のときは、鍵と値の交互の配列を組の集まりとして比べ、組の順番を見ない。
 * Swift の JSONEncoder は辞書を決まらない順に書くため。PreservingConnections は並べ替えてから書くので、
 * Swift の SettingsStore が書いた値どうしは順番まで比べる。
 */
fun assertSameJson(expected: ByteArray, actual: ByteArray, message: String, unorderedPairs: Boolean = false) {
    val expectedJson = assertNotNull(StoredJson.parse(expected), "$message: 期待する値が JSON ではない")
    val actualJson = assertNotNull(StoredJson.parse(actual), "$message: 書いた値が JSON ではない")
    if (unorderedPairs) {
        assertEquals(pairs(expectedJson), pairs(actualJson), message)
    } else {
        assertEquals(expectedJson, actualJson, message)
    }
}

private fun pairs(element: kotlinx.serialization.json.JsonElement): Set<Pair<kotlinx.serialization.json.JsonElement, kotlinx.serialization.json.JsonElement>> {
    val array = element as kotlinx.serialization.json.JsonArray
    return array.chunked(2).map { it[0] to it[1] }.toSet()
}
