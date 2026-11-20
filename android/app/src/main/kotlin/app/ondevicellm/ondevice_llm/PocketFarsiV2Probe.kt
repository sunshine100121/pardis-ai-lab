package app.ondevicellm.ondevice_llm

import android.content.Context
import android.os.Handler
import android.os.Looper
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.LongBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import org.json.JSONObject

/**
 * EXPERIMENTAL: genuine local ONNX execution of Persian ByT5 G2P.
 *
 * This is not a TTS/speech playback adapter yet. Do NOT register it as
 * a speaking engine or replace the user's working Gyro. It proves the
 * first native inference stage, before implementing FlowLM/Mimi/PCM.
 *
 * No weights, tokenizer, references or downloads ship with the APK.
 */
internal class PocketFarsiV2Probe(
    private val context: Context,
    messenger: BinaryMessenger
) {
    private val busy = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private val dir = File(context.filesDir, "voice_models/pocket_farsi_v2")

    init {
        MethodChannel(messenger, "pala/pocket_farsi_v2_probe")
            .setMethodCallHandler { call, result ->
                if (call.method != "inspect" && call.method != "phonemise") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (!busy.compareAndSet(false, true)) {
                    result.error("POCKET_BUSY", "Pocket model diagnostic is already running", null)
                    return@setMethodCallHandler
                }
                val method = call.method
                val text = call.argument<String>("text")
                thread(name = "pala-pocket-onnx-probe", isDaemon = true) {
                    try {
                        val status = inspectPackage()
                        if (method == "inspect") {
                            main.post { result.success(status) }
                        } else if (status["ready"] != true) {
                            main.post {
                                result.error("POCKET_PACK_MISSING", "Pocket model package is incomplete", status)
                            }
                        } else if (text.isNullOrBlank()) {
                            main.post { result.error("POCKET_EMPTY_TEXT", "Text is empty", null) }
                        } else {
                            val phonemes = phonemise(text)
                            main.post { result.success(mapOf(
                                "phonemes" to phonemes,
                                "engine" to "native-onnx-byt5-greedy",
                                "stage" to "g2p-only",
                                "audioGenerated" to false
                            )) }
                        }
                    } catch (e: Exception) {
                        // Never echo raw paths or user text in diagnostics.
                        main.post { result.error("POCKET_PROBE_FAILED", e.javaClass.simpleName, null) }
                    } finally {
                        busy.set(false)
                    }
                }
            }
    }

    private fun inspectPackage(): Map<String, Any> {
        val files = listOf(
            "manifest.json", "flow_lm_step.onnx", "flow_lm_step.onnx.data",
            "mimi_encoder.onnx", "mimi_encoder.onnx.data",
            "mimi_decoder_step_kv.onnx", "mimi_decoder_step_kv.onnx.data",
            "g2p_encoder.onnx", "g2p_decoder.onnx", "g2p_decoder.onnx.data",
            "weights.npz", "decode_state_init.npz", "tokenizer_ph.model",
            "voice_reference.wav"
        )
        // The last file is separate from Nimaone's ONNX model package.
        val missing = files.filter { name ->
            val file = File(dir, name)
            !file.isFile || file.length() <= 0L ||
                file.canonicalFile.parentFile != dir.canonicalFile
        }
        if (missing.isNotEmpty()) return mapOf(
            "ready" to false,
            "missing" to missing,
            "audioGenerated" to false
        )
        val constants = JSONObject(File(dir, "manifest.json").readText()).getJSONObject("constants")
        if (constants.getInt("sample_rate") != 24000 ||
            constants.getInt("ldim") != 32) {
            return mapOf("ready" to false, "missing" to emptyList<String>(),
                "reason" to "unsupported-manifest", "audioGenerated" to false)
        }
        return mapOf("ready" to true, "missing" to emptyList<String>(),
            "audioGenerated" to false, "stage" to "native-onnx-g2p-probe")
    }

    /**
     * ByT5: each UTF-8 source byte becomes token byte+3, PAD=0, EOS=1.
     * Port of the unmodified greedy ONNX semantics in persian_tts/g2p_onnx.py.
     * Text normalization/transliteration parity still needs device testing.
     */
    /** Diagnostic-only entry used by the isolated native synthesis prototype. */
    internal fun phonemiseLocal(text: String): String = phonemise(text)

    private fun phonemise(text: String): String {
        val normalized = PocketFarsiNumberWords.normalize(text)
            .replace('ي', 'ی').replace('ك', 'ک')
            .replace(Regex("[\\u064B-\\u065F\\u0670]"), "")
            .replace(Regex("\\s+"), " ").trim()
        if (normalized.length > 300 || !normalized.any { it in '\u0600'..'\u06FF' }) {
            throw IllegalArgumentException("Unsupported or overlong input")
        }
        // Until the full Persian normalizer is ported, reject mixed Latin,
        // digits, or other formats instead of silently dropping words.
        if (normalized.any { it in 'A'..'Z' || it in 'a'..'z' || it.isDigit() }) {
            throw IllegalArgumentException("Text normalization is not complete")
        }
        val sourceBytes = normalized.toByteArray(Charsets.UTF_8)
        if (sourceBytes.size > 512) throw IllegalArgumentException("Input too long")
        val inputIds = LongArray(sourceBytes.size) { i -> (sourceBytes[i].toInt() and 255).toLong() + 3L }
        val env = OrtEnvironment.getEnvironment()
        val opts = OrtSession.SessionOptions()
        opts.setIntraOpNumThreads(2)
        opts.setInterOpNumThreads(1)
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        try {
            env.createSession(File(dir, "g2p_encoder.onnx").absolutePath, opts).use { encoder ->
                env.createSession(File(dir, "g2p_decoder.onnx").absolutePath, opts).use { decoder ->
                    val hidden = longTensor(env, inputIds).use { input ->
                        encoder.run(mapOf("input_ids" to input)).use { output ->
                            output[0].value
                        }
                    }
                    val decoded = ArrayList<Int>()
                    val tokens = ArrayList<Long>()
                    tokens.add(0L)
                    var ended = false
                    for (step in 0 until 512) {
                        val scores = longTensor(env, tokens.toLongArray()).use { decoderIds ->
                            OnnxTensor.createTensor(env, hidden).use { encoderHidden ->
                                decoder.run(mapOf(
                                    "decoder_input_ids" to decoderIds,
                                    "encoder_hidden" to encoderHidden
                                )).use { output ->
                                    val batch = output[0].value as Array<*>
                                    val time = batch[0] as Array<*>
                                    (time[time.size - 1] as FloatArray).copyOf()
                                }
                            }
                        }
                        var bestIndex = 0
                        for (i in 1 until scores.size) if (scores[i] > scores[bestIndex]) bestIndex = i
                        if (bestIndex == 1) { ended = true; break }
                        tokens.add(bestIndex.toLong())
                        decoded.add(bestIndex)
                    }
                    if (!ended) throw IllegalStateException("G2P did not terminate")
                    val utf8 = ByteArrayOutputStream()
                    for (id in decoded) if (id in 3..258) utf8.write(id - 3)
                    val raw = utf8.toString(Charsets.UTF_8.name())
                    val output = buildString {
                        for (c in raw) append(when (c) {
                            '/' -> 'a'; 'a' -> 'A'; '@' -> '?'; '$' -> 'S'; 'c' -> 'C'
                            else -> c
                        })
                    }.replace("bo?d", "ba?d").replace("1", "").trim()
                    if (output.isBlank()) throw IllegalStateException("Empty G2P output")
                    return output
                }
            }
        } finally {
            opts.close()
        }
    }

    private fun longTensor(env: OrtEnvironment, ids: LongArray): OnnxTensor =
        OnnxTensor.createTensor(env, LongBuffer.wrap(ids), longArrayOf(1L, ids.size.toLong()))
}
