package app.ondevicellm.ondevice_llm

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * EXPERIMENTAL native-ONNX synthesis, not yet device-verified:
 * G2P -> SentencePiece -> Mimi voice encoder -> FlowLM -> Mimi decoder -> PCM.
 * Never registers as the active TTS; Gyro remains untouched.
 */
internal class PocketFarsiV2Audio(
    private val context: Context,
    messenger: BinaryMessenger,
    private val g2p: PocketFarsiV2Probe
) {
    private val dir = File(context.filesDir, "voice_models/pocket_farsi_v2")
    private val busy = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "pala/pocket_farsi_v2_audio")
            .setMethodCallHandler { call, response ->
                if (call.method != "synthesize") {
                    response.notImplemented()
                    return@setMethodCallHandler
                }
                val text = call.argument<String>("text") ?: ""
                if (text.isBlank() || text.length > 250) {
                    response.error("POCKET_TEXT_INVALID", "Short Persian text required", null)
                    return@setMethodCallHandler
                }
                if (!busy.compareAndSet(false, true)) {
                    response.error("POCKET_BUSY", "Pocket already generating", null)
                    return@setMethodCallHandler
                }
                thread(name = "pala-pocket-native-tts", isDaemon = true) {
                    try {
                        val memory = ActivityManager.MemoryInfo()
                        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                            .getMemoryInfo(memory)
                        if (memory.lowMemory || memory.availMem < 1_500_000_000L) {
                            throw IllegalStateException("Memory pressure")
                        }
                        val start = System.nanoTime()
                        val pcm = generate(text)
                        val ms = (System.nanoTime() - start) / 1_000_000
                        main.post { response.success(mapOf(
                            "pcm" to pcm, "rate" to 24000,
                            "generationMs" to ms,
                            "audioMs" to (pcm.size.toLong() * 1000 / 48000),
                            "audioGenerated" to pcm.isNotEmpty(),
                            "engine" to "pocket-farsi-v2-native-onnx-prototype"
                        )) }
                    } catch (e: Exception) {
                        // Never include the owner's text, reference audio or paths.
                        main.post { response.error(
                            "POCKET_AUDIO_UNVERIFIED", e.javaClass.simpleName, null
                        ) }
                    } finally {
                        busy.set(false)
                    }
                }
            }
    }

    private fun modelFile(name: String): File {
        if (!name.matches(Regex("[a-zA-Z0-9_.-]+"))) error("Invalid model name")
        val file = File(dir, name)
        if (!file.isFile || file.length() == 0L ||
            file.canonicalFile.parentFile != dir.canonicalFile
        ) error("Missing Pocket model asset")
        return file
    }

    private fun generate(text: String): ByteArray {
        val c = JSONObject(modelFile("manifest.json").readText()).getJSONObject("constants")
        val rate = c.getInt("sample_rate")
        val ldim = c.getInt("ldim")
        val dim = c.getInt("dim")
        val layers = c.getInt("layers")
        val heads = c.getInt("heads")
        val depth = c.getInt("dim_per_head")
        val cap = c.getInt("cache_capacity")
        val steps = c.getInt("mimi_steps_per_latent")
        val temperature = c.getDouble("temp")
        val tokensPerSecond = c.getDouble("tokens_per_second_estimate")
        val padding = c.getDouble("gen_seconds_padding")
        val frameRate = c.getDouble("frame_rate")
        if (rate != 24000 || ldim != 32 || dim != 1024 || layers !in 1..8 ||
            heads !in 1..32 || depth !in 1..128 || cap !in 128..1024 ||
            steps !in 1..64 || temperature !in 0.01..2.0 ||
            tokensPerSecond !in 1.0..20.0 || padding !in 0.0..10.0 ||
            frameRate !in 1.0..100.0
        ) error("Unsupported Pocket manifest")

        val phonemes = g2p.phonemiseLocal(text)
        val tokenizer = PocketPhonemeTokenizer.load(modelFile("tokenizer_ph.model"))
        val chunks = splitPhonemes(phonemes, tokenizer)
        if (chunks.isEmpty() || chunks.size > 12) error("Unsafe phoneme length")
        val weights = PocketNpz.read(modelFile("weights.npz"), 72L * 1024 * 1024)
        val lut = weights["lut_weight"]?.floats ?: error("Missing LUT")
        val projection = weights["speaker_proj"]?.floats ?: error("Missing projection")
        val bos = weights["bos_before_voice"]?.floats ?: error("Missing voice BOS")
        val std = weights["emb_std"]?.floats ?: error("Missing standard deviation")
        val mean = weights["emb_mean"]?.floats ?: error("Missing embedding mean")
        if (lut.size != 4000 * dim || projection.size != dim * ldim ||
            bos.size != dim || std.size != ldim || mean.size != ldim
        ) error("Unsupported embedding dimensions")
        val voice = readVoice(modelFile("voice_reference.wav"), rate)
        val states = PocketNpz.read(modelFile("decode_state_init.npz"))
        val env = OrtEnvironment.getEnvironment()
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            setInterOpNumThreads(1)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        try {
            env.createSession(modelFile("mimi_encoder.onnx").absolutePath, options).use { enc ->
                env.createSession(modelFile("flow_lm_step.onnx").absolutePath, options).use { flow ->
                    env.createSession(modelFile("mimi_decoder_step_kv.onnx").absolutePath, options)
                        .use { dec ->
                            val voiceTensor = run(env, enc, mapOf(
                                "audio" to PocketTensor.of(
                                    longArrayOf(1, 1, voice.size.toLong()), voice
                                )
                            ))["latent"] ?: error("Voice encoder returned no latent")
                            val conditioned = conditionVoice(
                                voiceTensor, projection, bos, dim, ldim
                            )
                            val clean = PocketTensor.of(
                                longArrayOf(layers.toLong(), 2L, cap.toLong(),
                                    heads.toLong(), depth.toLong()),
                                FloatArray(layers * 2 * cap * heads * depth)
                            )
                            val offsetStart = stepFlow(env, flow, ldim, dim, clean, 0,
                                FloatArray(0), conditioned, FloatArray(ldim)).second
                            val result = ByteArrayOutputStream()
                            val rng = Random()
                            var spoken = 0
                            for (chunk in chunks) {
                                val tokenIds = tokenizer.encode(chunk)
                                if (tokenIds.isEmpty() || tokenIds.size > 20) {
                                    error("Flow token cap exceeded")
                                }
                                val embed = FloatArray(tokenIds.size * dim)
                                for (index in tokenIds.indices) {
                                    val id = tokenIds[index]
                                    if (id !in 0 until 4000) error("Invalid phoneme token id")
                                    System.arraycopy(lut, id * dim, embed, index * dim, dim)
                                }
                                val cache = clean.copy()
                                var offset = offsetStart
                                val latentSeq = ArrayList<FloatArray>()
                                val first = stepFlow(env, flow, ldim, dim, cache, offset,
                                    FloatArray(ldim) { Float.NaN }, embed,
                                    noise(rng, ldim, temperature))
                                var last = first.first.first
                                offset = first.second
                                latentSeq.add(last)
                                val maxFrames = min(160, ceil(
                                    (tokenIds.size / tokensPerSecond + padding) * frameRate
                                ).toInt())
                                var eosSteps = 0
                                val tail = (if (chunk.split(' ').size <= 4) 3 else 1) + 2
                                for (step in 0 until maxFrames) {
                                    if (offset + 1 > cap) break
                                    val next = stepFlow(env, flow, ldim, dim, cache, offset,
                                        last, FloatArray(0), noise(rng, ldim, temperature))
                                    last = next.first.first
                                    offset = next.second
                                    if (next.first.second) eosSteps++
                                    else if (eosSteps > 0) eosSteps++
                                    if (eosSteps > tail) break
                                    latentSeq.add(last)
                                }
                                val decoded = decode(env, dec, latentSeq, states,
                                    std, mean, ldim, steps)
                                val output = trim(decoded, rate)
                                spoken += output.size
                                if (spoken > rate * 90) error("Generation exceeded 90 s")
                                if (result.size() > 0) result.write(ByteArray(rate * 12 / 100 * 2))
                                appendPcm(result, output)
                            }
                            if (result.size() < rate / 5) error("No speech was produced")
                            return result.toByteArray()
                        }
                }
            }
        } finally {
            options.close()
        }
    }

    private fun splitPhonemes(text: String, tokenizer: PocketPhonemeTokenizer): List<String> {
        val result = ArrayList<String>()
        var current = ""
        for (word in text.split(Regex("\\s+")).filter(String::isNotEmpty)) {
            val trial = if (current.isEmpty()) word else "$current $word"
            if (tokenizer.encode(trial).size <= 18) {
                current = trial
            } else {
                if (current.isEmpty()) error("Unsplit phoneme exceeds budget")
                result.add(current)
                current = word
                if (tokenizer.encode(current).size > 18) error("Unsplit phoneme exceeds budget")
            }
        }
        if (current.isNotEmpty()) result.add(current)
        return result
    }

    private fun readVoice(file: File, rate: Int): FloatArray {
        val raw = file.readBytes()
        if (raw.size !in 44..(rate * 5 * 2 + 4096)) error("Invalid reference duration")
        if (String(raw, 0, 4, Charsets.US_ASCII) != "RIFF" ||
            String(raw, 8, 4, Charsets.US_ASCII) != "WAVE"
        ) error("Expected RIFF WAV")
        val bb = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        var validFormat = false
        var dataStart = -1
        var dataLength = 0
        while (offset + 8 <= raw.size) {
            val kind = String(raw, offset, 4, Charsets.US_ASCII)
            val size = bb.getInt(offset + 4)
            if (size < 0 || offset.toLong() + 8 + size > raw.size) error("Invalid WAV chunk")
            if (kind == "fmt " && size >= 16) {
                validFormat = bb.getShort(offset + 8).toInt() == 1 &&
                    bb.getShort(offset + 10).toInt() == 1 &&
                    bb.getInt(offset + 12) == rate &&
                    bb.getShort(offset + 22).toInt() == 16
            }
            if (kind == "data") {
                dataStart = offset + 8
                dataLength = size
            }
            offset += 8 + size + (size and 1)
        }
        if (!validFormat || dataStart < 0 || dataLength !in rate..(rate * 5 * 2)) {
            error("Reference must be 24kHz mono PCM16 WAV, 0.5-5 seconds")
        }
        return FloatArray(dataLength / 2) { index ->
            bb.getShort(dataStart + index * 2).toFloat() / 32768f
        }
    }

    private fun conditionVoice(
        voice: PocketTensor, projection: FloatArray, bos: FloatArray,
        dim: Int, ldim: Int
    ): FloatArray {
        if (voice.shape.size != 3 || voice.shape[0] != 1L ||
            voice.shape[2] != ldim.toLong() ||
            voice.shape[1] !in 1L..70L) error("Invalid reference encoding")
        val count = voice.shape[1].toInt()
        val input = voice.floats ?: error("Invalid Mimi output")
        val output = FloatArray((count + 1) * dim)
        System.arraycopy(bos, 0, output, 0, dim)
        for (t in 0 until count) for (d in 0 until dim) {
            var value = 0f
            for (i in 0 until ldim) value += input[t * ldim + i] * projection[d * ldim + i]
            output[(t + 1) * dim + d] = value
        }
        return output
    }

    private fun stepFlow(
        env: OrtEnvironment, model: OrtSession, ldim: Int, dim: Int,
        cache: PocketTensor, offset: Int, sequence: FloatArray,
        textEmb: FloatArray, noise: FloatArray
    ): Pair<Pair<FloatArray, Boolean>, Int> {
        if (sequence.size % ldim != 0 || textEmb.size % dim != 0) {
            error("Invalid FlowLM sequence shape")
        }
        val seq = sequence.size / ldim
        val words = textEmb.size / dim
        val width = seq + words
        if (width < 1 || offset + width > cache.shape[2].toInt()) error("Flow cache full")
        val output = run(env, model, mapOf(
            "sequence" to PocketTensor.of(longArrayOf(1, seq.toLong(), ldim.toLong()), sequence),
            "text_emb" to PocketTensor.of(longArrayOf(1, words.toLong(), dim.toLong()), textEmb),
            "offset" to PocketTensor.scalar(offset.toLong()),
            "noise" to PocketTensor.of(longArrayOf(1, ldim.toLong()), noise),
            "cache" to cache
        ))
        val latent = output["latent"]?.floats ?: error("No FlowLM latent")
        val eos = output["eos"]?.floats?.firstOrNull() ?: error("No FlowLM EOS")
        if (latent.size != ldim || !eos.isFinite()) error("Invalid FlowLM output")
        scatter(cache, output["new_kv"] ?: error("No KV cache delta"), offset)
        return (latent to (eos > 0.5f)) to (offset + width)
    }

    private fun scatter(dst: PocketTensor, src: PocketTensor, at: Int) {
        val a = dst.shape
        val b = src.shape
        if (a.size != 5 || b.size != 5 ||
            a[0] != b[0] || a[1] != b[1] || a[3] != b[3] || a[4] != b[4]
        ) error("Incompatible KV tensor")
        val cap = a[2].toInt()
        val steps = b[2].toInt()
        val stride = (a[3] * a[4]).toInt()
        if (at < 0 || at + steps > cap) error("KV cache overflow")
        val d = dst.floats ?: error("Invalid KV tensor")
        val s = src.floats ?: error("Invalid KV update")
        for (group in 0 until (a[0] * a[1]).toInt()) for (step in 0 until steps) {
            System.arraycopy(s, (group * steps + step) * stride,
                d, (group * cap + at + step) * stride, stride)
        }
    }

    private fun decode(
        env: OrtEnvironment, model: OrtSession, latents: List<FloatArray>,
        initial: LinkedHashMap<String, PocketTensor>, std: FloatArray,
        mean: FloatArray, ldim: Int, steps: Int
    ): FloatArray {
        val names = initial.keys.toList()
        val state = initial.values.map { it.copy() }.toMutableList()
        if (state.size !in 1..64) error("Invalid Mimi decoder state count")
        val small = names.indices.filter { !names[it].endsWith(".cache") }
        val cache = names.indices.filter { names[it].endsWith(".cache") }
        val output = ArrayList<FloatArray>()
        var size = 0
        for (index in latents.indices) {
            val latent = FloatArray(ldim) { j -> latents[index][j] * std[j] + mean[j] }
            val feeds = LinkedHashMap<String, PocketTensor>()
            feeds["latent"] = PocketTensor.of(longArrayOf(1, 1, ldim.toLong()), latent)
            for (i in state.indices) feeds["s$i"] = state[i]
            val results = run(env, model, feeds)
            val audio = results["audio"] ?: error("Missing Mimi waveform")
            if (audio.shape.size != 3 || audio.shape[0] != 1L ||
                audio.shape[1] != 1L) error("Unexpected Mimi waveform shape")
            val wave = audio.floats ?: error("Mimi did not return float samples")
            output.add(wave)
            size += wave.size
            for (j in small.indices) {
                state[small[j]] = results["s" + j + "o"] ?: error("Missing updated decoder state")
            }
            for (j in cache.indices) {
                scatter(state[cache[j]], results["kv" + j] ?: error("Missing Mimi KV"), index * steps)
            }
        }
        val combined = FloatArray(size)
        var pos = 0
        for (chunk in output) {
            System.arraycopy(chunk, 0, combined, pos, chunk.size)
            pos += chunk.size
        }
        return combined
    }

    private fun trim(wave: FloatArray, sampleRate: Int): FloatArray {
        if (wave.isEmpty()) error("No audio")
        val peak = wave.maxOf { kotlin.math.abs(it) }
        if (!peak.isFinite() || peak < 0.01f) error("Silent/invalid audio")
        val level = peak * 0.02f
        val head = max(0, wave.indexOfFirst { kotlin.math.abs(it) >= level } - sampleRate / 50)
        val tail = min(wave.size, wave.indexOfLast { kotlin.math.abs(it) >= level } + sampleRate / 15)
        if (tail <= head) error("No voiced samples")
        return wave.copyOfRange(head, tail).also { result ->
            val fade = min(result.size / 2, sampleRate / 125)
            for (i in 0 until fade) {
                val factor = i.toFloat() / max(1, fade)
                result[i] *= factor
                result[result.lastIndex - i] *= factor
            }
        }
    }

    private fun appendPcm(out: ByteArrayOutputStream, samples: FloatArray) {
        for (value in samples) {
            if (!value.isFinite()) error("Nonfinite audio")
            val v = (value.coerceIn(-0.98f, 0.98f) * 32767f).toInt()
            out.write(v and 255)
            out.write((v ushr 8) and 255)
        }
    }

    private fun noise(random: Random, n: Int, temp: Double) =
        FloatArray(n) { (random.nextGaussian() * sqrt(temp)).toFloat() }

    private fun run(
        env: OrtEnvironment, model: OrtSession, feeds: Map<String, PocketTensor>
    ): Map<String, PocketTensor> {
        val inputs = LinkedHashMap<String, OnnxTensor>()
        try {
            for ((name, data) in feeds) inputs[name] = data.toOrt(env)
            model.run(inputs).use { result ->
                val output = LinkedHashMap<String, PocketTensor>()
                for (name in model.outputNames) {
                    val tensor = result.get(name).orElseThrow() as OnnxTensor
                    output[name] = PocketTensor.fromOrt(tensor)
                }
                return output
            }
        } finally {
            for (tensor in inputs.values) tensor.close()
        }
    }
}
