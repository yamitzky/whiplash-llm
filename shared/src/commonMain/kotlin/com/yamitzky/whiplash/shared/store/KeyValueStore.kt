package com.yamitzky.whiplash.shared.store

/**
 * 保存先。macOS と iOS では UserDefaults、Android では SharedPreferences などで実装する。
 * 値の型は Swift の RoleStore と SettingsStore が UserDefaults に書く型 (Data、Int、Bool) に合わせている。
 */
interface KeyValueStore {
    fun getData(key: String): ByteArray?
    fun setData(key: String, value: ByteArray)

    /** 無ければ null。Swift の `integer(forKey:)` は無いと 0 を返すので、呼ぶ側で 0 として扱う。 */
    fun getInt(key: String): Int?
    fun setInt(key: String, value: Int)

    fun getBool(key: String): Boolean?
    fun setBool(key: String, value: Boolean)

    fun keys(): Set<String>
}

/** API キーの置き場。macOS と iOS では Keychain、Android では Keystore で暗号化した保存先などで実装する。 */
interface SecretStore {
    fun get(account: String): String?
    fun set(account: String, value: String)
    fun delete(account: String)
}

/** テストと、保存しなくてよい場面で使う。 */
class InMemoryKeyValueStore : KeyValueStore {
    val values: MutableMap<String, Any> = linkedMapOf()

    override fun getData(key: String): ByteArray? = values[key] as? ByteArray
    override fun setData(key: String, value: ByteArray) { values[key] = value.copyOf() }
    override fun getInt(key: String): Int? = values[key] as? Int
    override fun setInt(key: String, value: Int) { values[key] = value }
    override fun getBool(key: String): Boolean? = values[key] as? Boolean
    override fun setBool(key: String, value: Boolean) { values[key] = value }
    override fun keys(): Set<String> = values.keys.toSet()
}

class InMemorySecretStore : SecretStore {
    val values: MutableMap<String, String> = linkedMapOf()

    override fun get(account: String): String? = values[account]
    override fun set(account: String, value: String) { values[account] = value }
    override fun delete(account: String) { values.remove(account) }
}
