package com.yamitzky.whiplash.shared.store

import com.yamitzky.whiplash.shared.model.ResponsePattern
import com.yamitzky.whiplash.shared.model.Role
import kotlin.time.Clock
import kotlin.time.ExperimentalTime

/**
 * WhiplashCore の `RoleStore`。保存するキー、移行の手順、読めないときの退避先は Swift と同じにしている。
 * 同じ保存先を Swift のビルドと Kotlin のビルドが交互に読んでも、互いのロールを消さないため。
 */
class RoleStore(
    private val defaults: KeyValueStore,
    private val addsTranscriptionRole: Boolean = true,
    private val nowEpochSeconds: () -> Long = ::currentEpochSeconds,
) {
    var roles: List<Role> = emptyList()
        private set

    /** roles が変わるたびに呼ぶ。Swift からも Flow なしで購読できるよう、コールバックにしている。 */
    var onChange: ((List<Role>) -> Unit)? = null

    init {
        load()
    }

    private val initialRoles: List<Role>
        get() = if (addsTranscriptionRole) presets + transcriptionRole else presets

    fun load() {
        val data = defaults.getData(ROLES_KEY)
        if (data == null) {
            setRoles(initialRoles)
            save()
            defaults.setInt(SCHEMA_VERSION_KEY, SCHEMA_VERSION)
            return
        }
        try {
            setRoles(StoredJson.decodeRoles(data))
        } catch (_: StoredFormatException) {
            // 読めないだけで消してしまうと、利用者のプロンプトが二度と戻らない。
            defaults.setData("$ROLES_KEY.unreadable.${nowEpochSeconds()}", data)
            setRoles(initialRoles)
            return
        }
        migrateIfNeeded(original = data)
    }

    /** 形式を変えるときは SCHEMA_VERSION を上げる。移行前の原本は消さずに残す。 */
    private fun migrateIfNeeded(original: ByteArray) {
        val stored = defaults.getInt(SCHEMA_VERSION_KEY) ?: 0
        if (stored >= SCHEMA_VERSION) return
        val backupKey = "$ROLES_KEY.backup.v$stored"
        if (defaults.getData(backupKey) == null) {
            defaults.setData(backupKey, original)
        }
        // 名前を変えていても同じロールとわかるよう、固定の ID でも照合する。消したロールを毎回足し直さないよう、足すのは v4 への移行の一度だけ。
        if (stored < 4 && addsTranscriptionRole &&
            roles.none { it.id == transcriptionRole.id || it.name == transcriptionRole.name }
        ) {
            setRoles(roles + transcriptionRole)
        }
        save()
        defaults.setInt(SCHEMA_VERSION_KEY, SCHEMA_VERSION)
    }

    fun save() {
        defaults.setData(ROLES_KEY, StoredJson.encodeRoles(roles))
    }

    fun add(role: Role) {
        setRoles(roles + role)
        save()
    }

    fun update(role: Role) {
        val index = roles.indexOfFirst { it.id == role.id }
        if (index < 0) return
        setRoles(roles.toMutableList().also { it[index] = role })
        save()
    }

    fun delete(role: Role) {
        setRoles(roles.filter { it.id != role.id })
        save()
    }

    /** Swift の `move(fromOffsets:toOffset:)` と同じく、[toOffset] は移す前の並びでの位置。 */
    fun move(fromOffsets: Set<Int>, toOffset: Int) {
        setRoles(roles.moved(fromOffsets, toOffset))
        save()
    }

    private fun setRoles(value: List<Role>) {
        roles = value
        onChange?.invoke(value)
    }

    companion object {
        /**
         * v2: overlay を responsePatterns から additionalResponsePatterns へ移した。
         * v3: iOS の既存ユーザーにも「文字起こし」ロールを足した。
         * v4: macOS にも「文字起こし」ロールを足した。
         */
        const val SCHEMA_VERSION = 4
        const val SCHEMA_VERSION_KEY = "rolesSchemaVersion"
        const val ROLES_KEY = "roles"

        val transcriptionRole = Role(
            id = "5F0B7C9E-2D41-4A8B-9C63-7E1D2A4B8F10",
            name = "文字起こし",
            icon = "✍️",
            systemPrompt = "与えられた画像やテキストに書かれている文字を、そのまま書き起こしてください。要約・翻訳・言い換えはしないでください。改行や箇条書きなど元の構成はできるだけ保ち、読み取れない箇所は［判読不能］と書いてください。書き起こした本文だけを返してください。",
            responsePatterns = listOf(ResponsePattern.RichMessage),
        )

        /** Swift の `RoleStore.presets`。ID は Swift と同じく、プロセスを起動するたびに変わる。 */
        val presets: List<Role> = listOf(
            Role(
                name = "英訳",
                icon = "🌐",
                systemPrompt = "あなたは優秀な翻訳者です。与えられた日本語テキストを自然な英語に翻訳してください。翻訳結果のみを返してください。",
                responsePatterns = listOf(ResponsePattern.RichMessage),
            ),
            Role(
                name = "和訳",
                icon = "🇯🇵",
                systemPrompt = "あなたは優秀な翻訳者です。与えられた英語テキストを自然な日本語に翻訳してください。翻訳結果のみを返してください。",
                responsePatterns = listOf(ResponsePattern.RichMessage),
            ),
            Role(
                name = "メール返信",
                icon = "✉️",
                systemPrompt = "あなたはビジネスメールの専門家です。与えられたメール内容を読み取り、適切な返信文を日本語で生成してください。丁寧で簡潔な文面にしてください。",
                responsePatterns = listOf(ResponsePattern.RichMessage),
            ),
            Role(
                name = "要約",
                icon = "📝",
                systemPrompt = "与えられたテキストの内容を簡潔に要約してください。要点を箇条書きで示してください。",
                responsePatterns = listOf(ResponsePattern.RichMessage),
            ),
        )
    }
}

/** SwiftUI の `Array.move(fromOffsets:toOffset:)` と同じ並べ替え。 */
internal fun <T> List<T>.moved(fromOffsets: Set<Int>, toOffset: Int): List<T> {
    val moving = fromOffsets.filter { it in indices }.sorted().map { this[it] }
    val before = (0 until toOffset.coerceIn(0, size)).filter { it !in fromOffsets }.map { this[it] }
    val after = (toOffset.coerceIn(0, size) until size).filter { it !in fromOffsets }.map { this[it] }
    return before + moving + after
}

@OptIn(ExperimentalTime::class)
internal fun currentEpochSeconds(): Long = Clock.System.now().epochSeconds
