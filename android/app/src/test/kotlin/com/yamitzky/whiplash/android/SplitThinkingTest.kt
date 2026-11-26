package com.yamitzky.whiplash.android

import com.yamitzky.whiplash.shared.llm.Prompt
import kotlin.test.Test
import kotlin.test.assertEquals

class SplitThinkingTest {
    @Test
    fun `thinking が無ければ全部が本文`() {
        assertEquals(null to "本文", splitThinking(Prompt.displayText("本文", listOf(""))))
    }

    @Test
    fun `共有コアが組み立てた形を thinking と本文に分ける`() {
        assertEquals("考え中" to "本文", splitThinking(Prompt.displayText("本文", listOf("考え中"))))
    }

    @Test
    fun `閉じタグが届く前は全部を thinking として扱う`() {
        assertEquals("考え" to "", splitThinking("<thinking>考え"))
    }
}
