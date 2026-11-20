package app.ondevicellm.ondevice_llm

/**
 * Bounded G2P windows matching the intended upstream split policy.
 *
 * Persian G2P degrades on run-on sentences over ~30 words. These
 * windows keep every word and prefer a conjunction boundary, without
 * introducing spoken breaks in the original text.
 *
 * The ONNX sessions can be reused across all windows.
 */
internal object PocketFarsiG2pWindows {
    private const val LIMIT = 30
    private val conjunctions = setOf(
        "و", "یا", "ولی", "اما", "که", "زیرا", "چون", "پس",
        "سپس", "بنابراین", "همچنین"
    )

    fun plan(input: String): List<String> {
        val words = input.trim().split(Regex("\\s+")).filter(String::isNotBlank)
        if (words.isEmpty()) return emptyList()
        val output = ArrayList<String>()
        fun add(start: Int, end: Int) {
            if (end - start <= LIMIT) {
                output.add(words.subList(start, end).joinToString(" "))
                return
            }
            // A split on a conjunction leaves it as the first word of
            // the following window, as in upstream _g2p_windows.
            var cut = -1
            val maxIndex = minOf(end - start - 4, LIMIT - 3)
            for (i in LIMIT / 2 until maxIndex) {
                if (words[start + i] in conjunctions) cut = i
            }
            if (cut < 0) cut = LIMIT / 2
            if (cut <= 0 || cut >= end - start) error("Invalid G2P window")
            add(start, start + cut)
            add(start + cut, end)
        }
        add(0, words.size)
        check(output.size <= 256) { "Excessive G2P windows" }
        return output
    }
}
