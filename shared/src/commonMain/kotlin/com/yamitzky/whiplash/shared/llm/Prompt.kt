package com.yamitzky.whiplash.shared.llm

/** WhiplashCore の LLMService の `buildPrompt` と `displayText`。 */
object Prompt {
    /** 本文に追加指示を足す。追加指示が空なら本文だけ。 */
    fun build(fullText: String, additionalInstructions: String?): String {
        if (additionalInstructions.isNullOrEmpty()) return fullText
        return "$fullText\n\n---\n追加指示: $additionalInstructions"
    }

    /**
     * 思考過程を、macOS の StreamingText と iOS の StreamingResult が切り出す
     * `<thinking>…</thinking>\n\n本文` の形に組み立てる。形を変えるときは両方の UI を直す。
     */
    fun displayText(content: String, reasoning: List<String>): String {
        val thinking = reasoning.filter { it.isNotEmpty() }.joinToString("\n\n")
        if (thinking.isEmpty()) return content
        return "<thinking>$thinking</thinking>\n\n$content"
    }
}
