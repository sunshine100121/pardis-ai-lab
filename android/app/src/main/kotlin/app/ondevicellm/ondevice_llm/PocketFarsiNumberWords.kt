package app.ondevicellm.ondevice_llm

/** Deterministic spoken form for simple sensor numbers; no network or LLM. */
internal object PocketFarsiNumberWords {
    private val units = arrayOf(
        "صفر", "یک", "دو", "سه", "چهار", "پنج", "شش", "هفت", "هشت",
        "نه", "ده", "یازده", "دوازده", "سیزده", "چهارده", "پانزده",
        "شانزده", "هفده", "هجده", "نوزده"
    )
    private val tens = arrayOf("", "", "بیست", "سی", "چهل", "پنجاه",
        "شصت", "هفتاد", "هشتاد", "نود")
    private val hundreds = arrayOf("", "صد", "دویست", "سیصد", "چهارصد",
        "پانصد", "ششصد", "هفتصد", "هشتصد", "نهصد")

    private val pattern = Regex("(?<![\\p{L}\\p{N}])[-−]?[0-9۰-۹٠-٩]+(?:[.٫][0-9۰-۹٠-٩]+)?")

    fun normalize(text: String): String {
        val unitsExpanded = text.replace("٪", " درصد ").replace("%", " درصد ")
            .replace("°", " درجه ")
        return pattern.replace(unitsExpanded) { match -> spokenNumber(match.value) }
            .replace(Regex("\\s+"), " ").trim()
    }

    private fun toDecimalDigit(char: Char): Int = when (char) {
        in '0'..'9' -> char.code - '0'.code
        in '۰'..'۹' -> char.code - '۰'.code
        in '٠'..'٩' -> char.code - '٠'.code
        else -> error("Unsupported numeric digit")
    }

    private fun spokenNumber(token: String): String {
        val negative = token.startsWith("-") || token.startsWith("−")
        val positive = if (negative) token.drop(1) else token
        val pieces = positive.split('.', '٫')
        val digits = pieces[0].map { toDecimalDigit(it) }
        if (digits.size > 12) error("Pocket numeric value is too large")
        val number = digits.fold(0L) { n, d -> n * 10 + d }
        var result = integerWords(number)
        if (pieces.size > 1) {
            val decimals = pieces[1].map { toDecimalDigit(it) }
            if (decimals.size > 6) error("Pocket numeric fraction is too long")
            val fraction = if (decimals.size <= 2 && decimals.firstOrNull() != 0) {
                integerWords(decimals.fold(0L) { n, d -> n * 10 + d })
            } else {
                decimals.joinToString(" ") { units[it] }
            }
            result += " ممیز " + fraction
        }
        return if (negative) "منفی " + result else result
    }

    private fun integerWords(number: Long): String {
        if (number < 20) return units[number.toInt()]
        if (number < 100) {
            val t = tens[(number / 10).toInt()]
            val u = number % 10
            return if (u == 0L) t else "$t و " + units[u.toInt()]
        }
        if (number < 1000) {
            val h = hundreds[(number / 100).toInt()]
            val remainder = number % 100
            return if (remainder == 0L) h else "$h و " + integerWords(remainder)
        }
        val groups = arrayOf(
            1_000_000_000L to "میلیارد",
            1_000_000L to "میلیون",
            1000L to "هزار"
        )
        for ((value, label) in groups) {
            if (number >= value) {
                val lead = integerWords(number / value) + " " + label
                val rest = number % value
                return if (rest == 0L) lead else lead + " و " + integerWords(rest)
            }
        }
        error("Unsupported numeric input")
    }
}
