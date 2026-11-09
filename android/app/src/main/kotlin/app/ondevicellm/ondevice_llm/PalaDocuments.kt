package app.ondevicellm.ondevice_llm

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Engine-owned read-only SAF handles; worker serializes close/read races. */
class PalaDocuments(private val context: Context, messenger: BinaryMessenger) {
    var activity: Activity? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val handles = mutableMapOf<Int, AssetFileDescriptor>()
    private var next = 0
    private var picking: MethodChannel.Result? = null
    private val channel = MethodChannel(messenger, "pala/documents")
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "pick") {
                val owner = activity
                if (owner == null || picking != null) result.error("picker", "فایل‌گزین در دسترس نیست", null)
                else {
                    picking = result
                    try {
                        owner.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            type = "*/*"
                            addCategory(Intent.CATEGORY_OPENABLE)
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }, REQUEST)
                    } catch (e: Exception) { picking = null; result.error("picker", e.message, null) }
                }
            } else worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "open" -> {
                            val uri = Uri.parse(call.arguments as String)
                            require(uri.scheme == "content")
                            val a = context.contentResolver.openAssetFileDescriptor(uri, "r")
                                ?: error("فایل در دسترس نیست")
                            try {
                                // Reject pipes; never spool a provider's stream into app storage.
                                Os.lseek(a.fileDescriptor, 0, OsConstants.SEEK_CUR)
                                val stat = Os.fstat(a.fileDescriptor)
                                val size = if (a.declaredLength >= 0) a.declaredLength else stat.st_size - a.startOffset
                                require(size >= 80 && a.startOffset >= 0) { "فایل قابل خواندن تصادفی نیست" }
                                val probe = ByteArray(4)
                                require(Os.pread(a.fileDescriptor, probe, 0, 4, a.startOffset) == 4)
                                val id = ++next
                                handles[id] = a
                                mapOf("handle" to id, "size" to size)
                            } catch (e: Exception) { a.close(); throw e }
                        }
                        "read" -> {
                            val id = call.argument<Number>("handle")!!.toInt()
                            val offset = call.argument<Number>("offset")!!.toLong()
                            val count = call.argument<Number>("count")!!.toInt()
                            require(offset >= 0 && count in 0..1048576)
                            val a = handles[id] ?: error("منبع بسته شده است")
                            require(offset <= Long.MAX_VALUE - a.startOffset)
                            val bytes = ByteArray(count)
                            var done = 0
                            while (done < count) {
                                val n = Os.pread(a.fileDescriptor, bytes, done, count - done, a.startOffset + offset + done)
                                if (n <= 0) break
                                done += n
                            }
                            if (done == count) bytes else bytes.copyOf(done)
                        }
                        "close" -> { handles.remove((call.arguments as Number).toInt())?.close(); null }
                        "forget" -> {
                            val uri = Uri.parse(call.arguments as String)
                            context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            null
                        }
                        else -> throw IllegalArgumentException("Unknown document operation")
                    }
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    main.post { result.error("document", "منبع در دسترس نیست یا فایل‌گزین خواندن تصادفی را پشتیبانی نمی‌کند؛ فایل محلی دیگری انتخاب کنید. هیچ کپی ساخته نشد.", null) }
                }
            }
        }
    }
    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val result = picking ?: return true
        picking = null
        if (code != Activity.RESULT_OK || data == null) { result.success(emptyList<Any>()); return true }
        try {
            val uris = if (data.clipData != null) (0 until data.clipData!!.itemCount).map { data.clipData!!.getItemAt(it).uri }
                else listOfNotNull(data.data)
            val selected = uris.distinct().map { uri ->
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                var name = "دانشنامه"
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) name = c.getString(0) ?: name
                }
                mapOf("uri" to uri.toString(), "name" to name)
            }
            result.success(selected)
        } catch (e: Exception) { result.error("permission", "مجوز پایدار خواندن فایل دریافت نشد", null) }
        return true
    }
    fun detached() { activity = null; picking?.error("picker", "انتخاب فایل لغو شد", null); picking = null }
    fun close() {
        channel.setMethodCallHandler(null)
        detached()
        worker.execute { handles.values.forEach { it.close() }; handles.clear() }
        worker.shutdown()
    }
    companion object { const val REQUEST = 7403 }
}
