package com.yamitzky.whiplash.shared.store

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ImageInputMode
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ProviderConnection
import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import com.yamitzky.whiplash.shared.model.ThinkingConfig
import com.yamitzky.whiplash.shared.model.WhiplashId
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/** Swift の Codable が読めない値。読み込みの失敗をこの例外 1 つにまとめる。 */
class StoredFormatException(message: String) : Exception(message)

/**
 * WhiplashCore が UserDefaults に書く JSON と同じ形を読み書きする。
 *
 * kotlinx.serialization の `@Serializable` を使わず JsonElement を手で組むのは、Swift の手書きの
 * `init(from:)` / `encode(to:)` の規則 (未知の値を捨てる、別のキーに分けて書く、など) を 1 か所で読めるようにするため。
 * 読むときの厳しさは Swift の JSONDecoder に合わせる。Swift が読めない値を Kotlin が読めてしまうと、
 * Kotlin が書き戻した値を古い Swift のビルドが読めなくなる。
 */
object StoredJson {
    internal val json = Json

    fun parse(data: ByteArray): JsonElement? = try {
        json.parseToJsonElement(data.decodeToString(throwOnInvalidSequence = true))
    } catch (_: Exception) {
        null
    }

    fun encode(element: JsonElement): ByteArray = json.encodeToString(JsonElement.serializer(), element).encodeToByteArray()

    // MARK: - Role

    /**
     * 古いビルドは responsePatterns の未知の値で全ロールの読み込みに失敗し、プリセットで上書きする。
     * そのビルドが同じ保存先を読んでも壊れないよう、後から足した値は additionalResponsePatterns に分けて書く。
     */
    private val additionalPatterns = setOf(ResponsePattern.Overlay)

    fun decodeRole(element: JsonElement): Role {
        val obj = element.asObject("Role")
        // 別のバージョンが保存した未知の値で全ロールの読み込みを失敗させない。
        val stored = obj.requireStringArray("responsePatterns")
        val additional = obj.optionalStringArray("additionalResponsePatterns") ?: emptyList()
        val patterns = (stored + additional).mapNotNull(ResponsePattern::fromRawValue).distinct()
        return Role(
            id = obj.requireUuid("id"),
            name = obj.requireString("name"),
            icon = obj.requireString("icon"),
            systemPrompt = obj.requireString("systemPrompt"),
            responsePatterns = patterns,
            modelId = obj.optionalUuid("modelId"),
            // 未知の値で全ロールの読み込みを失敗させない。既定へ戻るのは、このロールの入力方式だけで済む。
            imageInputMode = obj.optionalString("imageInputMode")?.let(ImageInputMode::fromRawValue) ?: ImageInputMode.Image,
        )
    }

    fun encodeRole(role: Role): JsonObject = buildJsonObject {
        put("id", role.id)
        put("name", role.name)
        put("icon", role.icon)
        put("systemPrompt", role.systemPrompt)
        put("responsePatterns", stringArray(role.responsePatterns.filter { it !in additionalPatterns }.map { it.rawValue }))
        val additional = role.responsePatterns.filter { it in additionalPatterns }
        if (additional.isNotEmpty()) {
            put("additionalResponsePatterns", stringArray(additional.map { it.rawValue }))
        }
        role.modelId?.let { put("modelId", it) }
        put("imageInputMode", role.imageInputMode.rawValue)
    }

    /** RoleStore は Swift と同じく配列ごと読む。1 件でも読めなければ全体を読めないものとして扱う。 */
    fun decodeRoles(data: ByteArray): List<Role> {
        val array = parse(data) as? JsonArray ?: throw StoredFormatException("roles is not a JSON array")
        return array.map(::decodeRole)
    }

    fun encodeRoles(roles: List<Role>): ByteArray = encode(JsonArray(roles.map(::encodeRole)))

    // MARK: - ModelConfig

    /** Swift が合成した enum の Codable の形。`{"off":{}}`、`{"auto":{}}`、`{"budget":{"_0":2048}}`。 */
    fun decodeThinking(element: JsonElement): ThinkingConfig {
        val obj = element.asObject("ThinkingConfig")
        if (obj.size != 1) throw StoredFormatException("ThinkingConfig must have exactly one case: ${obj.keys}")
        val (case, payload) = obj.entries.single()
        val values = payload.asObject("ThinkingConfig.$case")
        return when (case) {
            "off" -> ThinkingConfig.Off
            "auto" -> ThinkingConfig.Auto
            "budget" -> ThinkingConfig.Budget(values.requireInt("_0"))
            else -> throw StoredFormatException("unknown ThinkingConfig case: $case")
        }
    }

    fun encodeThinking(thinking: ThinkingConfig): JsonObject = buildJsonObject {
        when (thinking) {
            ThinkingConfig.Off -> put("off", JsonObject(emptyMap()))
            ThinkingConfig.Auto -> put("auto", JsonObject(emptyMap()))
            is ThinkingConfig.Budget -> put("budget", buildJsonObject { put("_0", thinking.tokens) })
        }
    }

    fun decodeModel(element: JsonElement): ModelConfig {
        val obj = element.asObject("ModelConfig")
        return ModelConfig(
            id = obj.requireUuid("id"),
            name = obj.requireString("name"),
            provider = decodeProvider(obj["provider"] ?: throw StoredFormatException("missing provider")),
            modelIdentifier = obj.requireString("modelIdentifier"),
            thinking = obj.present("thinking")?.let(::decodeThinking) ?: ThinkingConfig.Off,
        )
    }

    fun encodeModel(model: ModelConfig): JsonObject = buildJsonObject {
        put("id", model.id)
        put("name", model.name)
        put("provider", model.provider.rawValue)
        put("modelIdentifier", model.modelIdentifier)
        put("thinking", encodeThinking(model.thinking))
    }

    // MARK: - Connections

    fun decodeProvider(element: JsonElement): BackendProvider {
        val raw = element.asString("BackendProvider")
        return BackendProvider.fromRawValue(raw) ?: throw StoredFormatException("unknown provider: $raw")
    }

    fun decodeConnection(element: JsonElement): ProviderConnection {
        val obj = element.asObject("ProviderConnection")
        return ProviderConnection(
            apiKey = obj.optionalString("apiKey"),
            // Swift の URL は空の文字列を読めない。
            endpoint = obj.optionalString("endpoint")?.also {
                if (it.isEmpty()) throw StoredFormatException("endpoint is empty")
            },
        )
    }

    fun encodeConnection(connection: ProviderConnection): JsonObject = buildJsonObject {
        connection.apiKey?.let { put("apiKey", it) }
        connection.endpoint?.let { put("endpoint", it) }
    }

    // MARK: - defaultModelId

    /** `"UUID"` なら ID、`null` なら null。それ以外は読めない。 */
    fun decodeOptionalUuid(data: ByteArray): Result<String?> {
        val element = parse(data) ?: return Result.failure(StoredFormatException("not JSON"))
        if (element is JsonNull) return Result.success(null)
        return runCatching { element.asUuid("defaultModelId") }
    }

    fun encodeOptionalUuid(id: String?): ByteArray = encode(id?.let(::JsonPrimitive) ?: JsonNull)
}

// MARK: - 読めない要素を残す読み書き

/**
 * 保存された JSON 配列を要素ごとに読む。読めない要素は原本の JSON のまま持ち、保存時に末尾へ書き戻す。
 * 配列ごと読むと、別のバージョンが書いた 1 要素 (未知のプロバイダーなど) で全体が読めなくなり、
 * 既定値で上書きして利用者の設定を消してしまう。Swift の `PreservingArray` と同じ。
 */
class PreservingArray<T>(val elements: List<T>, val unreadable: List<JsonElement>) {
    companion object {
        /** JSON の配列として読めなければ null。 */
        fun <T> decode(data: ByteArray, decodeElement: (JsonElement) -> T): PreservingArray<T>? {
            val array = StoredJson.parse(data) as? JsonArray ?: return null
            val elements = mutableListOf<T>()
            val unreadable = mutableListOf<JsonElement>()
            for (item in array) {
                try {
                    elements += decodeElement(item)
                } catch (_: StoredFormatException) {
                    unreadable += item
                }
            }
            return PreservingArray(elements, unreadable)
        }

        fun <T> encode(elements: List<T>, unreadable: List<JsonElement>, encodeElement: (T) -> JsonElement): ByteArray =
            StoredJson.encode(JsonArray(elements.map(encodeElement) + unreadable))
    }
}

/**
 * `[BackendProvider: ProviderConnection]` を読む。Swift の JSONEncoder は、鍵が String でない辞書を
 * `["openAI", {...}, "ollama", {...}]` と鍵と値を交互に並べた配列で書く。
 * 読めない組 (未知のプロバイダーなど) は原本のまま持ち、保存時に書き戻す。Swift の `PreservingConnections` と同じ。
 */
class PreservingConnections(
    val connections: Map<BackendProvider, ProviderConnection>,
    val unreadable: List<Pair<JsonElement, JsonElement>>,
) {
    companion object {
        /** 鍵と値が交互に並んだ配列として読めなければ null。 */
        fun decode(data: ByteArray): PreservingConnections? {
            val array = StoredJson.parse(data) as? JsonArray ?: return null
            if (array.size % 2 != 0) return null
            val connections = linkedMapOf<BackendProvider, ProviderConnection>()
            val unreadable = mutableListOf<Pair<JsonElement, JsonElement>>()
            for (index in array.indices step 2) {
                val key = array[index]
                val value = array[index + 1]
                try {
                    connections[StoredJson.decodeProvider(key)] = StoredJson.decodeConnection(value)
                } catch (_: StoredFormatException) {
                    unreadable += key to value
                }
            }
            return PreservingConnections(connections, unreadable)
        }

        fun encode(
            connections: Map<BackendProvider, ProviderConnection>,
            unreadable: List<Pair<JsonElement, JsonElement>>,
        ): ByteArray {
            val parts = mutableListOf<JsonElement>()
            for ((provider, connection) in connections.entries.sortedBy { it.key.rawValue }) {
                parts += JsonPrimitive(provider.rawValue)
                parts += StoredJson.encodeConnection(connection)
            }
            for ((key, value) in unreadable) {
                // 読めなかった組と同じプロバイダーを利用者が設定し直したら、新しい方だけを残す。
                val provider = runCatching { StoredJson.decodeProvider(key) }.getOrNull()
                if (provider != null && provider in connections) continue
                parts += key
                parts += value
            }
            return StoredJson.encode(JsonArray(parts))
        }
    }
}

// MARK: - Swift の JSONDecoder に合わせた取り出し

private fun JsonElement.asObject(what: String): JsonObject =
    this as? JsonObject ?: throw StoredFormatException("$what is not an object")

private fun JsonElement.asString(what: String): String {
    val primitive = this as? JsonPrimitive
    if (primitive == null || !primitive.isString) throw StoredFormatException("$what is not a string")
    return primitive.content
}

private fun JsonElement.asUuid(what: String): String =
    WhiplashId.normalize(asString(what)) ?: throw StoredFormatException("$what is not a UUID")

/** decodeIfPresent と同じく、キーが無いときと null のときは無いものとして扱う。 */
private fun JsonObject.present(key: String): JsonElement? = this[key]?.takeUnless { it is JsonNull }

private fun JsonObject.requireString(key: String): String =
    (this[key] ?: throw StoredFormatException("missing $key")).asString(key)

private fun JsonObject.optionalString(key: String): String? = present(key)?.asString(key)

private fun JsonObject.requireUuid(key: String): String =
    (this[key] ?: throw StoredFormatException("missing $key")).asUuid(key)

private fun JsonObject.optionalUuid(key: String): String? = present(key)?.asUuid(key)

private fun JsonObject.requireInt(key: String): Int {
    val primitive = this[key] as? JsonPrimitive
    if (primitive == null || primitive.isString) throw StoredFormatException("$key is not a number")
    return primitive.intOrNull ?: throw StoredFormatException("$key is not an Int")
}

private fun JsonObject.requireStringArray(key: String): List<String> {
    val array = this[key] as? JsonArray ?: throw StoredFormatException("$key is not an array")
    return array.map { it.asString(key) }
}

private fun JsonObject.optionalStringArray(key: String): List<String>? {
    val element = present(key) ?: return null
    val array = element as? JsonArray ?: throw StoredFormatException("$key is not an array")
    return array.map { it.asString(key) }
}

private fun stringArray(values: List<String>): JsonArray = buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }
