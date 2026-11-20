package app.ondevicellm.ondevice_llm

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.zip.ZipFile
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.TensorInfo
import ai.onnxruntime.OnnxJavaType

/**
 * Tensor assets for Pocket Farsi v2. No Python runtime or generated model code.
 * Strict reader: only little-endian contiguous float32/int64 npy entries.
 */
internal data class PocketTensor(
    val shape: LongArray,
    val floats: FloatArray? = null,
    val longs: LongArray? = null
) {
    val count: Int get() = (floats?.size ?: longs?.size) ?: 0

    fun toOrt(env: OrtEnvironment): OnnxTensor {
        return if (floats != null) {
            OnnxTensor.createTensor(env, FloatBuffer.wrap(floats), shape)
        } else {
            OnnxTensor.createTensor(env, LongBuffer.wrap(longs ?: error("Empty tensor")), shape)
        }
    }

    fun copy(): PocketTensor = PocketTensor(shape.copyOf(), floats?.copyOf(), longs?.copyOf())

    companion object {
        fun of(shape: LongArray, values: FloatArray) = PocketTensor(shape, floats = values)
        fun scalar(value: Long) = PocketTensor(longArrayOf(), longs = longArrayOf(value))
        fun fromOrt(t: OnnxTensor): PocketTensor {
            val shape = (t.info as TensorInfo).shape
            return if ((t.info as TensorInfo).type == OnnxJavaType.INT64) {
                val buffer = t.longBuffer
                val values = LongArray(buffer.remaining())
                buffer.get(values)
                PocketTensor(shape, longs = values)
            } else {
                val buffer = t.floatBuffer
                val values = FloatArray(buffer.remaining())
                buffer.get(values)
                of(shape, values)
            }
        }
    }
}

internal object PocketNpz {
    fun read(file: File, maxBytes: Long = 96L * 1024 * 1024): LinkedHashMap<String, PocketTensor> {
        if (!file.isFile || file.length() <= 0 || file.length() > maxBytes) {
            error("Invalid NPZ package")
        }
        val result = LinkedHashMap<String, PocketTensor>()
        var total = 0L
        ZipFile(file).use { zip ->
            val items = zip.entries()
            while (items.hasMoreElements()) {
                val e = items.nextElement()
                if (e.isDirectory || !e.name.matches(Regex("[a-zA-Z0-9_.-]+[.]npy"))) {
                    error("Unsafe NPZ entry")
                }
                if (e.size < 0 || e.size > maxBytes || total + e.size > maxBytes) {
                    error("NPZ entry exceeds memory cap")
                }
                val data = zip.getInputStream(e).use { it.readBytes() }
                total += data.size
                if (total > maxBytes) error("NPZ exceeds memory cap")
                val key = e.name.removeSuffix(".npy")
                if (result.put(key, parseNpy(data)) != null) error("Duplicate NPZ key")
            }
        }
        if (result.isEmpty()) error("NPZ is empty")
        return result
    }

    private fun parseNpy(data: ByteArray): PocketTensor {
        if (data.size < 10 || !data.copyOfRange(0, 6).contentEquals(
                byteArrayOf(0x93.toByte(), 78, 85, 77, 80, 89)
            )) error("Invalid NumPy header")
        val major = data[6].toInt() and 255
        if (major !in 1..3) error("Unsupported NumPy header")
        val little = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val sizeBytes = if (major == 1) 2 else 4
        val headerSize = if (sizeBytes == 2) (little.getShort(8).toInt() and 0xffff) else little.getInt(8)
        val headerStart = 8 + sizeBytes
        if (headerSize <= 0 || headerSize > 4096 || headerStart + headerSize > data.size) {
            error("NumPy header out of bounds")
        }
        val header = String(data, headerStart, headerSize, Charsets.ISO_8859_1)
        if (header.contains("'fortran_order': True")) error("Fortran order unsupported")
        val descr = Regex("['\"]descr['\"]\\s*:\\s*['\"]([^'\"]+)['\"]")
            .find(header)?.groupValues?.get(1) ?: error("Missing NumPy dtype")
        val shapeText = Regex("['\"]shape['\"]\\s*:\\s*\\(([^)]*)\\)")
            .find(header)?.groupValues?.get(1) ?: error("Missing NumPy shape")
        val dims = shapeText.split(",").mapNotNull { it.trim().takeIf(String::isNotEmpty)?.toLongOrNull() }
        if (dims.any { it < 0 } || dims.size > 8) error("Unsafe NumPy shape")
        val size = dims.fold(1L) { a, b -> Math.multiplyExact(a, b) }
        if (size > 15_000_000) error("Tensor too large")
        val offset = headerStart + headerSize
        val dataBytes = data.size - offset
        val b = ByteBuffer.wrap(data, offset, dataBytes).order(ByteOrder.LITTLE_ENDIAN)
        return when (descr) {
            "<f4", "|f4" -> {
                if (size * 4 != dataBytes.toLong()) error("NumPy float shape mismatch")
                PocketTensor.of(dims.toLongArray(), FloatArray(size.toInt()) { b.float })
            }
            "<i8", "|i8" -> {
                if (size * 8 != dataBytes.toLong()) error("NumPy integer shape mismatch")
                PocketTensor(dims.toLongArray(), longs = LongArray(size.toInt()) { b.long })
            }
            "<i4", "|i4" -> {
                if (size * 4 != dataBytes.toLong()) error("NumPy integer shape mismatch")
                PocketTensor(dims.toLongArray(), longs = LongArray(size.toInt()) { b.int.toLong() })
            }
            else -> error("Unsupported tensor type")
        }
    }
}

/** Minimal verified-format SentencePiece UNIGRAM reader; rejects BPE/unsupported models. */
internal class PocketPhonemeTokenizer private constructor(
    private val byFirst: Map<Char, List<Token>>,
    private val unknownId: Int,
    private val modelType: Int,
    private val activeByName: Map<String, Token>
) {
    internal data class Token(val piece: String, val id: Int, val score: Double)
    fun encode(text: String): IntArray {
        // SentencePiece dummy-prefix + escaped whitespace used by the phoneme model.
        val src = "▁" + text.trim().replace(Regex("\\s+"), "▁")
        if (src.length > 2048 || src.isEmpty()) error("Phoneme input too long")
        if (modelType == 2) return encodeBpe(src)
        val best = DoubleArray(src.length + 1) { Double.NEGATIVE_INFINITY }
        val from = IntArray(src.length + 1) { -1 }
        val token = IntArray(src.length + 1) { -1 }
        best[0] = 0.0
        for (i in src.indices) {
            if (!best[i].isFinite()) continue
            val matches = byFirst[src[i]] ?: emptyList()
            var found = false
            for (p in matches) {
                if (src.startsWith(p.piece, i)) {
                    val end = i + p.piece.length
                    val score = best[i] + p.score
                    if (score > best[end]) {
                        best[end] = score
                        token[end] = p.id
                        from[end] = i
                    }
                    found = true
                }
            }
            if (!found && i + 1 <= src.length && best[i] - 100.0 > best[i + 1]) {
                // Fail closed on unmapped characters instead of generating wrong speech.
                if (unknownId < 0) error("Unknown phoneme piece")
                best[i + 1] = best[i] - 100.0
                from[i + 1] = i
                token[i + 1] = unknownId
            }
        }
        if (!best[src.length].isFinite()) error("SentencePiece segmentation failed")
        val out = ArrayList<Int>()
        var pos = src.length
        while (pos > 0) {
            if (from[pos] !in 0 until pos) error("SentencePiece path missing")
            out.add(token[pos])
            pos = from[pos]
        }
        out.reverse()
        return out.toIntArray()
    }


    /** SentencePiece BPE: start at UTF-8 codepoints; merge highest-scored
     * eligible adjacent pair until no merge is available. Never substitute
     * a replacement token for an unknown Persian phoneme character.
     * Parity with the original tokenizer_ph.model is still a device gate.
     */
    private fun encodeBpe(src: String): IntArray {
        val segments = ArrayList<String>()
        var i = 0
        while (i < src.length) {
            val cp = Character.codePointAt(src, i)
            val value = String(Character.toChars(cp))
            if (!activeByName.containsKey(value)) {
                error("Unsupported BPE phoneme")
            }
            segments.add(value)
            i += Character.charCount(cp)
        }
        while (segments.size > 1) {
            var bestAt = -1
            var bestScore = Double.NEGATIVE_INFINITY
            for (k in 0 until segments.lastIndex) {
                val candidate = activeByName[segments[k] + segments[k + 1]]
                if (candidate != null && candidate.score > bestScore) {
                    bestAt = k
                    bestScore = candidate.score
                }
            }
            if (bestAt < 0) break
            segments[bestAt] = segments[bestAt] + segments[bestAt + 1]
            segments.removeAt(bestAt + 1)
        }
        return segments.map {
            activeByName[it]?.id ?: error("BPE phoneme token not in vocabulary")
        }.toIntArray()
    }

    companion object {
        fun load(file: File): PocketPhonemeTokenizer {
            if (!file.isFile || file.length() !in 1..4_000_000) error("Missing phoneme tokenizer")
            val reader = WireReader(file.readBytes())
            val tokens = ArrayList<Token>()
            var modelType = 1 // SentencePiece TrainerSpec default: UNIGRAM
            while (!reader.done) {
                val tag = reader.varint().toInt()
                val field = tag ushr 3
                val wire = tag and 7
                when {
                    field == 1 && wire == 2 -> {
                        val p = WireReader(reader.bytes())
                        var name = ""
                        var score = 0.0
                        var type = 1
                        while (!p.done) {
                            val pt = p.varint().toInt()
                            when (pt ushr 3) {
                                1 -> name = String(p.bytes(), Charsets.UTF_8)
                                2 -> score = Float.fromBits(p.fixed32()).toDouble()
                                3 -> type = p.varint().toInt()
                                else -> p.skip(pt and 7)
                            }
                        }
                        val id = tokens.size
                        tokens.add(Token(if (type == 1) name else "", id, score))
                    }
                    field == 2 && wire == 2 -> {
                        val spec = WireReader(reader.bytes())
                        while (!spec.done) {
                            val st = spec.varint().toInt()
                            if (st ushr 3 == 3) modelType = spec.varint().toInt()
                            else spec.skip(st and 7)
                        }
                    }
                    else -> reader.skip(wire)
                }
            }
            if (modelType !in 1..2 || tokens.isEmpty() || tokens.size > 100000) {
                error("Unsupported SentencePiece model")
            }
            val unknown = tokens.indexOfFirst { it.piece.isEmpty() }
            val active = tokens.filter { it.piece.isNotEmpty() }
            return PocketPhonemeTokenizer(active.groupBy { it.piece[0] }, unknown,
                modelType, active.associateBy { it.piece })
        }
    }
}

private class WireReader(private val data: ByteArray) {
    private var pos = 0
    val done: Boolean get() = pos >= data.size
    fun varint(): Long {
        var value = 0L
        for (shift in 0..63 step 7) {
            if (done) error("Truncated protobuf")
            val b = data[pos++].toInt() and 255
            value = value or ((b and 127).toLong() shl shift)
            if (b and 128 == 0) return value
        }
        error("Invalid protobuf varint")
    }
    fun bytes(): ByteArray {
        val n = varint()
        if (n < 0 || n > data.size - pos) error("Invalid protobuf length")
        return data.copyOfRange(pos, pos + n.toInt()).also { pos += n.toInt() }
    }
    fun fixed32(): Int {
        if (pos + 4 > data.size) error("Truncated fixed32")
        return ByteBuffer.wrap(data, pos, 4).order(ByteOrder.LITTLE_ENDIAN).int.also { pos += 4 }
    }
    fun skip(wire: Int) {
        when (wire) {
            0 -> varint()
            1 -> pos += 8
            2 -> bytes()
            5 -> pos += 4
            else -> error("Unknown protobuf wire type")
        }
        if (pos > data.size) error("Truncated protobuf")
    }
}
