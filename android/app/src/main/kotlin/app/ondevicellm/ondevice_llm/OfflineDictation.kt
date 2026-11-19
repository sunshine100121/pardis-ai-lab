package app.ondevicellm.ondevice_llm

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener as VoskRecognitionListener
import org.vosk.android.SpeechService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Local Android speech adapters: a verified on-device platform recognizer
 * and the separately installed Vosk model. No network recognizer is created.
 */
class OfflineDictation(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    companion object { const val PERMISSION_REQUEST = 7301 }

    private val channel = MethodChannel(messenger, "ondevice_llm/offline_dictation")
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var voskModel: Model? = null
    private var voskService: SpeechService? = null
    private var activeEngine = "android-local"
    private val voskCommitted = mutableListOf<String>()
    private var session: Int? = null
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null
    private var deadline: Runnable? = null

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> reportPersianSystemSupport(result)
            "downloadAndroidFa" -> requestPersianSystemModel(result)
            "openTtsSettings" -> try {
                try {
                    activity.startActivity(Intent("com.android.settings.TTS_SETTINGS"))
                } catch (_: android.content.ActivityNotFoundException) {
                    activity.startActivity(
                        Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS),
                    )
                }
                result.success(null)
            } catch (e: Exception) {
                result.error("tts_settings_unavailable", e.message, null)
            }
            "listen" -> {
                cancel()
                val engine = call.argument<String>("engine") ?: "android-local"
                if (engine == "vosk-fa") {
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        pending = call to result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    } else startVosk(call, result)
                    return
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                    !SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)) {
                    result.error("offline_unavailable", "An on-device speech recognizer is unavailable.", null)
                    return
                }
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    pending = call to result
                    activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                } else {
                    start(call, result)
                }
            }
            "stop" -> {
                // A permission dialog must not start recording after Stop.
                pending?.second?.error("cancelled", "Dictation cancelled.", null)
                pending = null
                try {
                    if (activeEngine == "vosk-fa") voskService?.stop()
                    else recognizer?.stopListening()
                    result.success(null)
                } catch (e: Exception) {
                    cancel()
                    result.error("dictation_failed", e.message, null)
                }
            }
            "cancel" -> { cancel(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun reportPersianSystemSupport(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)) {
            result.success(mapOf("androidOfflineAvailable" to false, "androidOfflineSupported" to false, "androidOfflinePending" to false, "androidOfflineCanRequest" to false, "apiLevel" to Build.VERSION.SDK_INT))
            return
        }
        try {
            val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "fa-IR")
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            engine.checkRecognitionSupport(intent, activity.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        val installed = support.installedOnDeviceLanguages
                        val isFa: (String) -> Boolean = { it.equals("fa", true) || it.startsWith("fa-", true) || it.startsWith("fa_", true) }
                        val available = installed.any(isFa)
                        val supported = support.supportedOnDeviceLanguages.any(isFa)
                        val pending = support.pendingOnDeviceLanguages.any(isFa)
                        engine.destroy()
                        result.success(mapOf("androidOfflineAvailable" to available, "androidOfflineSupported" to supported, "androidOfflinePending" to pending, "androidOfflineCanRequest" to true, "apiLevel" to Build.VERSION.SDK_INT))
                    }
                    override fun onError(error: Int) {
                        engine.destroy()
                        result.success(mapOf("androidOfflineAvailable" to false, "androidOfflineSupported" to false, "androidOfflinePending" to false, "androidOfflineCanRequest" to true, "apiLevel" to Build.VERSION.SDK_INT))
                    }
                })
        } catch (_: Exception) {
            result.success(mapOf("androidOfflineAvailable" to false, "androidOfflineSupported" to false, "androidOfflinePending" to false, "androidOfflineCanRequest" to true, "apiLevel" to Build.VERSION.SDK_INT))
        }
    }

    private fun requestPersianSystemModel(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)) {
            result.error("offline_model_download_unsupported",
                "Android cannot request an on-device language pack.", null)
            return
        }
        // A missing entry in supportedOnDeviceLanguages is not proof that
        // the dedicated on-device recognizer cannot fetch the language.
        // Only explicit user action reaches this method.
        var engine: SpeechRecognizer? = null
        try {
            engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "fa-IR")
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            engine.triggerModelDownload(intent)
            result.success(null) // Request sent, never installation confirmation.
        } catch (e: Exception) {
            result.error("offline_model_download_failed", e.message, null)
        } finally {
            engine?.destroy()
        }
    }

    fun onPermissionResult(granted: Boolean) {
        val request = pending ?: return
        pending = null
        if (!granted) {
            request.second.error("error_permission", "Microphone permission is needed for dictation.", null)
        } else {
            if (request.first.argument<String>("engine") == "vosk-fa") {
                startVosk(request.first, request.second)
            } else {
                start(request.first, request.second)
            }
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<Int>("session")
        if (token == null) {
            result.error("invalid_session", "Missing dictation session.", null)
            return
        }
        try {
            // Recheck after the permission dialog; services may have changed.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                !SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)) {
                result.error("offline_unavailable", "An on-device speech recognizer is unavailable.", null)
                return
            }
            session = token
            activeEngine = "android-local"
            val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            recognizer = engine
            engine.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onPartialResults(results: Bundle?) { transcript(token, results, false) }
                override fun onResults(results: Bundle?) { transcript(token, results, true) }
                override fun onError(error: Int) {
                    if (session != token) return
                    val code = when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_permission"
                        SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "error_language_unavailable"
                        else -> "offline_recognition_failed"
                    }
                    channel.invokeMethod("error", mapOf("session" to token, "code" to code))
                    release()
                }
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                call.argument<String>("localeId")?.takeIf { it.isNotBlank() }?.let {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, it.replace('_', '-'))
                }
            }
            engine.startListening(intent)
            // Bound recording even if the service never sends a terminal event.
            deadline = Runnable {
                if (session == token) {
                    channel.invokeMethod("error", mapOf("session" to token, "code" to "error_speech_timeout"))
                    release()
                }
            }.also { handler.postDelayed(it, 60_000) }
            result.success(null)
        } catch (e: Exception) {
            release()
            result.error("offline_recognition_failed", e.message, null)
        }
    }

    private fun startVosk(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<Int>("session")
        val modelPath = call.argument<String>("modelPath")
        if (token == null || modelPath.isNullOrBlank()) {
            result.error("vosk_model_unavailable", "Vosk Persian model is not installed.", null)
            return
        }
        try {
            session = token
            activeEngine = "vosk-fa"
            voskCommitted.clear()
            Thread {
                try {
                    val model = voskModel ?: Model(modelPath).also { voskModel = it }
                    val decoder = Recognizer(model, 16000.0f)
                    val service = SpeechService(decoder, 16000.0f)
                    handler.post {
                        if (session != token) {
                            service.stop()
                            service.shutdown()
                            return@post
                        }
                        voskService = service
                        service.startListening(object : VoskRecognitionListener {
                            override fun onPartialResult(hypothesis: String?) {
                                if (session != token) return
                                val partial = hypothesisText(hypothesis, "partial")
                                channel.invokeMethod("result", mapOf(
                                    "session" to token,
                                    "text" to (voskCommitted + partial).filter(String::isNotBlank).joinToString(" "),
                                    "final" to false,
                                ))
                            }

                            override fun onResult(hypothesis: String?) {
                                if (session != token) return
                                val segment = hypothesisText(hypothesis, "text")
                                if (segment.isNotBlank() && voskCommitted.lastOrNull() != segment) {
                                    voskCommitted.add(segment)
                                }
                                channel.invokeMethod("result", mapOf(
                                    "session" to token,
                                    "text" to voskCommitted.joinToString(" "),
                                    "final" to false,
                                ))
                            }

                            override fun onFinalResult(hypothesis: String?) {
                                if (session != token) return
                                val segment = hypothesisText(hypothesis, "text")
                                if (segment.isNotBlank() && voskCommitted.lastOrNull() != segment) {
                                    voskCommitted.add(segment)
                                }
                                channel.invokeMethod("result", mapOf(
                                    "session" to token,
                                    "text" to voskCommitted.joinToString(" "),
                                    "final" to true,
                                ))
                                release()
                            }

                            override fun onError(exception: Exception?) {
                                if (session != token) return
                                channel.invokeMethod("error", mapOf(
                                    "session" to token,
                                    "code" to "offline_recognition_failed",
                                ))
                                release()
                            }

                            override fun onTimeout() {
                                if (session != token) return
                                channel.invokeMethod("result", mapOf(
                                    "session" to token,
                                    "text" to voskCommitted.joinToString(" "),
                                    "final" to true,
                                ))
                                release()
                            }
                        })
                    }
                } catch (e: Exception) {
                    handler.post {
                        if (session == token) {
                            channel.invokeMethod("error", mapOf(
                                "session" to token,
                                "code" to "offline_recognition_failed",
                            ))
                            release()
                        }
                    }
                }
            }.start()
            result.success(null)
        } catch (e: Exception) {
            release()
            result.error("offline_recognition_failed", e.message, null)
        }
    }

    private fun hypothesisText(raw: String?, field: String): String = try {
        JSONObject(raw ?: "{}").optString(field, "").trim()
    } catch (_: Exception) { "" }

    private fun transcript(token: Int, result: Bundle?, isFinal: Boolean) {
        if (session != token) return
        val text = result?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
        channel.invokeMethod("result", mapOf("session" to token, "text" to text, "final" to isFinal))
        if (isFinal) release()
    }

    private fun release() {
        session = null
        deadline?.let { handler.removeCallbacks(it) }
        deadline = null
        val old = recognizer
        recognizer = null
        try { old?.cancel() } catch (_: Exception) {}
        try { old?.destroy() } catch (_: Exception) {}
        val oldVosk = voskService
        voskService = null
        try { oldVosk?.stop() } catch (_: Exception) {}
        try { oldVosk?.shutdown() } catch (_: Exception) {}
        activeEngine = "android-local"
    }

    fun cancel() {
        val oldSession = session
        session = null
        oldSession?.let { channel.invokeMethod("error", mapOf("session" to it, "code" to "cancelled")) }
        pending?.second?.error("cancelled", "Dictation cancelled.", null)
        pending = null
        if (activeEngine == "vosk-fa") {
            val current = voskService
            if (current != null) {
                try { current.stop() } catch (_: Exception) {}
                try { current.shutdown() } catch (_: Exception) {}
                voskService = null
            }
        }
        release()
    }

    fun close() {
        cancel()
        channel.setMethodCallHandler(null)
        try { voskModel?.close() } catch (_: Exception) {}
        voskModel = null
    }
}
