package app.ondevicellm.ondevice_llm

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PocketFarsiNativeTest {
    @Test fun persianArabicDigitsAndFractionsAreSpoken() {
        assertEquals(
            "دمای باغ بیست و سه ممیز پنج درجه است",
            PocketFarsiNumberWords.normalize("دمای باغ ۲۳٫۵° است")
        )
        assertEquals(
            "رطوبت پنجاه درصد است",
            PocketFarsiNumberWords.normalize("رطوبت ٥٠٪ است")
        )
        assertEquals(
            "منفی ده",
            PocketFarsiNumberWords.normalize("−۱۰")
        )
        assertEquals(
            "دوازده ممیز صفر پنج",
            PocketFarsiNumberWords.normalize("۱۲٫۰۵")
        )
    }

    @Test fun latinBrandsAndArabicFormsNeverSilentlyDisappear() {
        assertEquals("مدل کوئن آماده است", PocketFarsiNormalizer.normalize("مدل Qwen آماده است"))
        assertEquals("می‌رود", PocketFarsiNormalizer.normalize("می‌رود"))
        assertEquals("آب و هوا", PocketFarsiNormalizer.normalize("آب و هوا"))
    }

    @Test fun sentencePieceBpeMergesByModelScore() {
        val f = File.createTempFile("pocket-bpe", ".model")
        try {
            val bytes = ByteArrayOutputStream()
            fun varint(value: Int): ByteArray {
                var v = value
                val out = ByteArrayOutputStream()
                while (v >= 128) {
                    out.write((v and 127) or 128)
                    v = v ushr 7
                }
                out.write(v)
                return out.toByteArray()
            }
            fun field(output: ByteArrayOutputStream, tag: Int, data: ByteArray) {
                output.write(varint(tag * 8 + 2))
                output.write(varint(data.size))
                output.write(data)
            }
            fun piece(name: String, score: Float, type: Int) {
                val p = ByteArrayOutputStream()
                field(p, 1, name.toByteArray(Charsets.UTF_8))
                p.write(varint(2 * 8 + 5))
                val value = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
                    .putFloat(score).array()
                p.write(value)
                p.write(varint(3 * 8))
                p.write(varint(type))
                field(bytes, 1, p.toByteArray())
            }
            piece("<unk>", -999f, 2)
            piece("▁", 0f, 1)
            piece("س", -1f, 1)
            piece("ل", -1f, 1)
            piece("▁س", 3f, 1)
            piece("▁سل", 4f, 1)
            val trainer = ByteArrayOutputStream()
            trainer.write(varint(3 * 8))
            trainer.write(varint(2)) // SentencePiece model_type=BPE
            field(bytes, 2, trainer.toByteArray())
            f.writeBytes(bytes.toByteArray())
            assertArrayEquals(intArrayOf(5), PocketPhonemeTokenizer.load(f).encode("سل"))
        } finally {
            f.delete()
        }
    }
}
