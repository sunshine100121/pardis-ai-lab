package app.ondevicellm.ondevice_llm

import android.content.Context
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.googlecode.tesseract.android.TessBaseAPI
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Explicitly requested, offline-only OCR of a single bounded PDF page bitmap.
 * Tessdata is installed into the app's private files directory by Dart after
 * exact official Git-blob verification. No URL, PDF or text is sent out.
 * Only one page is processed at a time; no file in AI Knowledge is modified.
 */
class PalaPdfOcr(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val channel = MethodChannel(messenger, "pala/pdf_ocr")
    @Volatile private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "recognize" -> {
                    val png = call.argument<ByteArray>("png")
                    val dataPath = call.argument<String>("dataPath")
                    val language = call.argument<String>("language")
                    if (closed || png == null || png.size > 12 * 1024 * 1024 ||
                        png.isEmpty || dataPath.isNullOrBlank() ||
                        language !in setOf("fas", "eng", "fas+eng")
                    ) {
                        result.error("PDF_OCR_BAD_INPUT", "Invalid OCR page request", null)
                        return@setMethodCallHandler
                    }
                    val root = File(dataPath).canonicalFile
                    val privateRoot = context.filesDir.canonicalPath + File.separator
                    if (!root.path.startsWith(privateRoot) ||
                        !File(root, "tessdata/fas.traineddata").isFile ||
                        !File(root, "tessdata/eng.traineddata").isFile
                    ) {
                        result.error("PDF_OCR_MODEL_MISSING", "Verified OCR models required", null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        var api: TessBaseAPI? = null
                        var bitmap: android.graphics.Bitmap? = null
                        try {
                            bitmap = BitmapFactory.decodeByteArray(png, 0, png.size)
                                ?: error("Unreadable rendered PDF page")
                            require(bitmap.width > 0 && bitmap.height > 0 &&
                                bitmap.width.toLong() * bitmap.height.toLong() <= 4_000_000L
                            ) { "Rendered OCR page exceeds pixel cap" }
                            api = TessBaseAPI()
                            if (!api.init(root.absolutePath, language)) {
                                error("Cannot load the pinned OCR language data")
                            }
                            api.setImage(bitmap)
                            val recognized = api.getUTF8Text() ?: ""
                            val confidence = api.meanConfidence().coerceIn(0, 100)
                            val text = recognized.take(65536)
                            main.post {
                                if (!closed) result.success(
                                    mapOf("text" to text, "confidence" to confidence,
                                        "language" to language, "engine" to "tesseract-local")
                                )
                            }
                        } catch (error: Exception) {
                            main.post {
                                if (!closed) result.error(
                                    "PDF_OCR_FAILED", error.message ?: "OCR error", null)
                            }
                        } finally {
                            api?.recycle()
                            bitmap?.recycle()
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
