package com.yamitzky.whiplash.shared.store

import com.yamitzky.whiplash.shared.model.BackendProvider
import com.yamitzky.whiplash.shared.model.ModelConfig
import com.yamitzky.whiplash.shared.model.ProviderConnection
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * WhiplashCore の `SettingsStore`。保存するキーと形式、読めない要素を残す規則は Swift と同じにしている。
 *
 * Swift と違う点:
 * - 保存された defaultModelId が `null` のとき、Swift の JSONDecoder は `UUID?` として読めずに退避する。
 *   Swift 自身が最後のモデルを消したときに書く値なので、Kotlin では読めない値として退避せず、先頭のモデルを使う。
 *   どちらも defaultModelId の値は同じになる。
 * - connections が無いときの、Keychain 導入前の古いキー (apiKeys、providerConfig、backendConfig) からの移行はしない。
 *   それらは古い macOS のビルドだけが書いたキーで、Android には無い。
 */
class SettingsStore(
    private val defaults: KeyValueStore,
    private val secrets: SecretStore,
    private val nowEpochSeconds: () -> Long = ::currentEpochSeconds,
) {
    /** 読み込み中は setter から保存しない。読めなかった原本を、読み込みのついでに上書きしないため。 */
    private var loading = true

    var connections: Map<BackendProvider, ProviderConnection> = emptyMap()
        set(value) {
            field = value
            saveConnections()
            notifyChange()
        }

    var models: List<ModelConfig> = emptyList()
        set(value) {
            field = value
            saveModels()
            notifyChange()
        }

    var defaultModelId: String? = null
        set(value) {
            field = value
            saveDefaultModelId()
            notifyChange()
        }

    /** true は Enter で送信し Shift+Enter で改行する。false (既定) は Ctrl+Enter で送信し Enter で改行する。 */
    var enterToSend: Boolean = false
        set(value) {
            field = value
            if (!loading) defaults.setBool(ENTER_TO_SEND_KEY, value)
            notifyChange()
        }

    /** 設定が変わるたびに呼ぶ。Swift からも Flow なしで購読できるよう、コールバックにしている。 */
    var onChange: (() -> Unit)? = null

    /** 別のバージョンが書いた、このビルドでは読めない要素。保存のたびに書き戻して消さない。 */
    private var unreadableConnections: List<Pair<JsonElement, JsonElement>> = emptyList()
    private var unreadableModels: List<JsonElement> = emptyList()

    init {
        val enterToSendStored = defaults.getBool(ENTER_TO_SEND_KEY) ?: false

        val loadedConnections: Map<BackendProvider, ProviderConnection>
        val connectionsData = defaults.getData(CONNECTIONS_KEY)
        if (connectionsData != null) {
            val loaded = PreservingConnections.decode(connectionsData)
            if (loaded != null) {
                loadedConnections = loaded.connections
                unreadableConnections = loaded.unreadable
            } else {
                backUpUnreadable(withoutApiKeys(connectionsData), CONNECTIONS_KEY)
                loadedConnections = emptyMap()
            }
        } else {
            loadedConnections = emptyMap()
        }

        val modelsData = defaults.getData(MODELS_KEY)
        val loadedModels: List<ModelConfig> = if (modelsData != null) {
            val loaded = PreservingArray.decode(modelsData, StoredJson::decodeModel)
            if (loaded != null) {
                unreadableModels = loaded.unreadable
                loaded.elements
            } else {
                backUpUnreadable(modelsData, MODELS_KEY)
                ModelConfig.builtinDefaults
            }
        } else {
            ModelConfig.builtinDefaults
        }
        val modelsWereMissing = modelsData == null

        val defaultModelIdData = defaults.getData(DEFAULT_MODEL_ID_KEY)
        val loadedDefaultModelId: String? = if (defaultModelIdData != null) {
            val decoded = StoredJson.decodeOptionalUuid(defaultModelIdData)
            if (decoded.isSuccess) {
                // 読めない要素として残したモデルを指していても書き換えない。defaultModel が先頭へ代替する。
                decoded.getOrNull() ?: loadedModels.firstOrNull()?.id
            } else {
                backUpUnreadable(defaultModelIdData, DEFAULT_MODEL_ID_KEY)
                loadedModels.firstOrNull()?.id
            }
        } else {
            loadedModels.firstOrNull()?.id
        }

        enterToSend = enterToSendStored
        connections = loadedConnections
        models = loadedModels
        defaultModelId = loadedDefaultModelId
        loading = false

        // builtinDefaults の ID は起動ごとに作り直されるので、保存しないとロールが選んだモデルを次の起動で見失う。
        // 既にある値は、読めなかった原本も含めて書き換えない。
        if (modelsWereMissing) saveModels()
        if (modelsWereMissing && defaultModelIdData == null) saveDefaultModelId()

        migrateApiKeysToSecrets()
    }

    // MARK: - Computed

    val defaultModel: ModelConfig?
        get() = models.firstOrNull { it.id == defaultModelId } ?: models.firstOrNull()

    fun model(id: String?): ModelConfig? {
        if (id == null) return defaultModel
        return models.firstOrNull { it.id == id } ?: defaultModel
    }

    fun connection(provider: BackendProvider): ProviderConnection = connections[provider] ?: ProviderConnection()

    fun endpoint(provider: BackendProvider): String = connections[provider]?.endpoint ?: provider.defaultEndpoint

    fun apiKey(provider: BackendProvider): String? = secrets.get(apiKeyAccount(provider))

    // MARK: - Mutations

    fun setApiKey(key: String?, provider: BackendProvider) {
        if (!key.isNullOrEmpty()) {
            secrets.set(apiKeyAccount(provider), key)
        } else {
            secrets.delete(apiKeyAccount(provider))
        }
    }

    fun setEndpoint(endpoint: String?, provider: BackendProvider) {
        connections = connections + (provider to connection(provider).copy(endpoint = endpoint))
    }

    fun addModel(model: ModelConfig) {
        models = models + model
        if (models.size == 1) {
            defaultModelId = model.id
        }
    }

    fun updateModel(model: ModelConfig) {
        val index = models.indexOfFirst { it.id == model.id }
        if (index < 0) return
        models = models.toMutableList().also { it[index] = model }
    }

    fun moveModel(fromOffsets: Set<Int>, toOffset: Int) {
        models = models.moved(fromOffsets, toOffset)
    }

    fun deleteModel(id: String) {
        models = models.filter { it.id != id }
        if (defaultModelId == id) {
            defaultModelId = models.firstOrNull()?.id
        }
    }

    // MARK: - Persistence

    // 変えたキーだけを書く。読めなかった別のキーを、関係のない変更のついでに上書きしないため。
    private fun saveConnections() {
        if (loading) return
        defaults.setData(CONNECTIONS_KEY, PreservingConnections.encode(connections, unreadableConnections))
    }

    private fun saveModels() {
        if (loading) return
        defaults.setData(MODELS_KEY, PreservingArray.encode(models, unreadableModels, StoredJson::encodeModel))
    }

    private fun saveDefaultModelId() {
        if (loading) return
        defaults.setData(DEFAULT_MODEL_ID_KEY, StoredJson.encodeOptionalUuid(defaultModelId))
    }

    private fun notifyChange() {
        if (!loading) onChange?.invoke()
    }

    private fun migrateApiKeysToSecrets() {
        for ((provider, connection) in connections) {
            val key = connection.apiKey
            if (!key.isNullOrEmpty()) {
                secrets.set(apiKeyAccount(provider), key)
                connections = connections + (provider to connection.copy(apiKey = null))
            }
        }
    }

    /**
     * 読めなかった値を `<key>.unreadable.<時刻>` に残す。同じ中身が残っていれば重ねて残さない
     * (読めないまま起動を繰り返すたびに増えないように)。
     */
    private fun backUpUnreadable(data: ByteArray, key: String): String {
        val prefix = "$key.unreadable."
        defaults.keys().firstOrNull { it.startsWith(prefix) && defaults.getData(it)?.contentEquals(data) == true }
            ?.let { return it }
        val backupKey = prefix + nowEpochSeconds()
        defaults.setData(backupKey, data)
        return backupKey
    }

    companion object {
        const val CONNECTIONS_KEY = "connections"
        const val MODELS_KEY = "models_v2"
        const val DEFAULT_MODEL_ID_KEY = "defaultModelId"
        const val ENTER_TO_SEND_KEY = "enterToSend"

        fun apiKeyAccount(provider: BackendProvider): String = "apiKey-${provider.rawValue}"

        /**
         * Keychain 移行前の connections には API キーが平文で入っている。原本は移行で消えるので、
         * バックアップにだけ平文の API キーが残り続けないよう取り除く。
         * JSON として読めないものは取り除きようがないので、そのまま残す (消すと戻せない)。
         */
        internal fun withoutApiKeys(data: ByteArray): ByteArray {
            val element = StoredJson.parse(data) ?: return data
            fun strip(value: JsonElement): JsonElement = when (value) {
                is JsonObject -> JsonObject(value.filterKeys { it != "apiKey" }.mapValues { strip(it.value) })
                is JsonArray -> JsonArray(value.map(::strip))
                else -> value
            }
            return StoredJson.encode(strip(element))
        }
    }
}
