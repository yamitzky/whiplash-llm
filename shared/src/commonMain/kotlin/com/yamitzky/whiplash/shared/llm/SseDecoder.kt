package com.yamitzky.whiplash.shared.llm

/**
 * Server-Sent Events の行を受けて、イベント 1 件分の data を返す。
 * 空行でイベントが終わり、data 行が複数あれば改行でつなぐ。`:` で始まる行 (コメント) と data 以外の項目は捨てる。
 */
internal class SseDecoder {
    private val data = StringBuilder()
    private var hasData = false

    fun feed(line: String): String? {
        if (line.isEmpty()) return finish()
        if (line.startsWith(":")) return null
        val field = line.substringBefore(':')
        if (field != "data") return null
        val value = if (':' in line) line.substringAfter(':').removePrefix(" ") else ""
        if (hasData) data.append('\n')
        data.append(value)
        hasData = true
        return null
    }

    /** 最後の空行が無いまま接続が切れたときの残り。 */
    fun finish(): String? {
        if (!hasData) return null
        val result = data.toString()
        data.clear()
        hasData = false
        return result
    }
}
