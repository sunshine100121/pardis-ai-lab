package app.ondevicellm.ondevice_llm

import java.text.Normalizer

/**
 * Defensive native Persian frontend, adapted from the public v2
 * normalize_fa.py conventions. Unknown *letter scripts* fail closed;
 * punctuation and emoji may be removed, but never meaningful words.
 * Full parity with the upstream Python normalizer remains a device gate.
 */
internal object PocketFarsiNormalizer {
    private val letters = "آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهیئ"
    private val allowed = letters.toSet() + setOf('‌', ' ', '.', '،', '؛', '؟', '!', ':')
    private val map = mapOf(
        'ي' to 'ی', 'ى' to 'ی', 'ۍ' to 'ی', 'ې' to 'ی',
        'ك' to 'ک', 'ڪ' to 'ک',
        'ة' to 'ه', 'ۀ' to 'ه', 'أ' to 'ا', 'إ' to 'ا',
        'ٱ' to 'ا', 'ٲ' to 'ا', 'ٳ' to 'ا', 'ؤ' to 'و',
        'ۂ' to 'ه', 'ۃ' to 'ه'
    )
    private val latinWords = Regex("[A-Za-z][A-Za-z'-]*")
    private val lettersLatin = mapOf(
        'a' to "ا", 'b' to "ب", 'c' to "ک", 'd' to "د", 'e' to "",
        'f' to "ف", 'g' to "گ", 'h' to "ه", 'i' to "ی",
        'j' to "ج", 'k' to "ک", 'l' to "ل", 'm' to "م",
        'n' to "ن", 'o' to "او", 'p' to "پ", 'q' to "ق",
        'r' to "ر", 's' to "س", 't' to "ت", 'u' to "و",
        'v' to "و", 'w' to "و", 'x' to "کس", 'y' to "ی",
        'z' to "ز"
    )
    private val digraphs = mapOf(
        "sh" to "ش", "ch" to "چ", "th" to "ث", "ph" to "ف",
        "gh" to "غ", "kh" to "خ", "wh" to "و", "ck" to "ک",
        "qu" to "کو", "oo" to "و", "ee" to "ی", "ea" to "ی",
        "ou" to "او", "au" to "او", "ai" to "ای", "ay" to "ای",
        "ey" to "ای", "oi" to "اوی", "oy" to "اوی"
    )
    private val names = mapOf(
        "pala" to "پالا",
        "qwen" to "کوئن",
        "pocket" to "پاکت",
        "gyro" to "جیرو",
        "hayai" to "هایایی",
        "wifi" to "وای فای",
        "windows" to "ویندوز",
        "python" to "پایتون",
        "network" to "نت ورک",
        "echo" to "اکو"
    )

    private fun transliterateWord(word: String): String {
        val lowered = word.lowercase()
        names[lowered]?.let { return it }
        val result = StringBuilder()
        var i = 0
        while (i < lowered.length) {
            val pair = lowered.substring(i, (i + 2).coerceAtMost(lowered.length))
            val matched = digraphs[pair]
            if (matched != null && pair.length == 2) {
                result.append(matched)
                i += 2
            } else {
                result.append(lettersLatin[lowered[i]] ?: " ")
                i++
            }
        }
        if (result.isBlank()) error("Untranslatable Latin word")
        return result.toString()
    }

    fun normalize(raw: String): String {
        if (raw.isBlank() || raw.length > 300) {
            error("Pocket text is empty or too long")
        }
        var text = Normalizer.normalize(raw, Normalizer.Form.NFC)
        // Keep U+200C between Persian letters. Remove other direction and
        // invisible controls (including BOM, ZWSP and ZWJ).
        text = text.replace(Regex("[\\u200B\\u200D\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF\\u00AD]"), "")
        text = text.replace(Regex("[\\u064B-\\u065F\\u0670\\u06D6-\\u06ED]"), "")
            .replace("ـ", "").replace("ء", "")
        text = buildString {
            for (c in text) append(map[c] ?: c)
        }
        text = text.replace("٬", "").replace("٫", ".")
        text = PocketFarsiNumberWords.normalize(text)
        text = latinWords.replace(text) { match -> transliterateWord(match.value) }
        text = text.replace(',', '،').replace('?', '؟').replace(';', '؛')
            .replace("–", "،").replace("—", "،")
        val body = StringBuilder()
        for (c in text) {
            when {
                c in allowed -> body.append(c)
                c == '\n' || c == '\t' -> body.append(' ')
                c.isLetter() -> error("Unsupported non-Persian script")
                c.isDigit() -> error("A numeric token was not normalized")
                else -> body.append(' ')
            }
        }
        val output = body.toString()
            .replace(Regex("\\s+"), " ")
            .replace(Regex("‌+"), "‌")
            .trim()
            .trimStart('.', '،', '؛', '؟', '!', ':', ' ')
            .replace(Regex(" +([.،؛؟!:])"), "$1")
        if (output.isBlank() || output.none { it in letters }) {
            error("Persian normalization produced no words")
        }
        return output
    }
}
