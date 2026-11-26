package com.yamitzky.whiplash.shared.model

/** WhiplashCore の `ResponsePattern`。[rawValue] が保存される文字列。 */
enum class ResponsePattern(val rawValue: String) {
    RichMessage("richMessage"),
    Clipboard("clipboard"),
    Overlay("overlay"),
    ;

    companion object {
        fun fromRawValue(rawValue: String): ResponsePattern? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** WhiplashCore の `ImageInputMode`。 */
enum class ImageInputMode(val rawValue: String) {
    Image("image"),
    Ocr("ocr"),
    ;

    companion object {
        fun fromRawValue(rawValue: String): ImageInputMode? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * WhiplashCore の `Role`。保存形式は [com.yamitzky.whiplash.shared.store.StoredJson] が読み書きする。
 *
 * ID は Swift の `UUID` が書く大文字の文字列で持つ。Kotlin の Uuid は小文字で書くので、
 * そのまま保存すると Swift と違う文字列になる。
 */
data class Role(
    val id: String = WhiplashId.random(),
    val name: String,
    val icon: String,
    val systemPrompt: String,
    val responsePatterns: List<ResponsePattern>,
    val modelId: String? = null,
    val imageInputMode: ImageInputMode = ImageInputMode.Image,
) {
    /**
     * 結果は常にボックスで見せ、コピーするかだけをロールで選ぶ。
     * richMessage を外すとボックスが出ずにトーストだけで終わり、結果を見失うため。
     */
    val copiesToClipboard: Boolean get() = ResponsePattern.Clipboard in responsePatterns

    /** Swift の `copiesToClipboard` の setter と同じく、overlay などほかの値は消える。 */
    fun withCopiesToClipboard(copies: Boolean): Role = copy(
        responsePatterns = if (copies) {
            listOf(ResponsePattern.RichMessage, ResponsePattern.Clipboard)
        } else {
            listOf(ResponsePattern.RichMessage)
        },
    )
}
