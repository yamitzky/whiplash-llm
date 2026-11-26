package com.yamitzky.whiplash.android

import android.content.SharedPreferences
import android.util.Base64
import com.yamitzky.whiplash.shared.store.KeyValueStore

/**
 * 共有コアの [KeyValueStore] を SharedPreferences で実装する。
 * SharedPreferences はバイト列を持てないので、Data は Base64 の文字列で置く。
 * Int と Bool はそのままの型で置き、型が違う値は無いものとして返す。
 */
class SharedPreferencesKeyValueStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun getData(key: String): ByteArray? {
        val encoded = prefs.all[key] as? String ?: return null
        return runCatching { Base64.decode(encoded, Base64.NO_WRAP) }.getOrNull()
    }

    override fun setData(key: String, value: ByteArray) {
        prefs.edit().putString(key, Base64.encodeToString(value, Base64.NO_WRAP)).apply()
    }

    override fun getInt(key: String): Int? = prefs.all[key] as? Int

    override fun setInt(key: String, value: Int) {
        prefs.edit().putInt(key, value).apply()
    }

    override fun getBool(key: String): Boolean? = prefs.all[key] as? Boolean

    override fun setBool(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }

    override fun keys(): Set<String> = prefs.all.keys.toSet()
}
