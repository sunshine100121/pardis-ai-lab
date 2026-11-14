package app.ondevicellm.ondevice_llm

import android.app.Activity
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract as D
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Activity-owned, read-only folder access. No model/runtime ownership. */
class KnowledgeDocuments(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "pala/documents")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("pala_knowledge_tree_v1", 0)
    private val resolver = activity.contentResolver
    private val handles = mutableMapOf<Int, AssetFileDescriptor>()
    private var next = 0
    private var picking: MethodChannel.Result? = null
    private var closed = false
    init { channel.setMethodCallHandler { call, result ->
        if (call.method == "pickTree") {
            if (picking != null) result.error("busy", "انتخاب پوشه در حال انجام است", null)
            else { picking = result
                try { activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                }, REQUEST) } catch (_: Exception) { picking = null; result.error("picker", "انتخاب پوشه ممکن نشد", null) }
            }
        } else worker.execute {
            try {
                check(!closed)
                val value: Any? = when(call.method) {
                    "listTree" -> listTree()
                    "open" -> {
                        val uri = Uri.parse(call.arguments as String)
                        val tree = Uri.parse(prefs.getString("tree", null) ?: error("no tree"))
                        require(uri.scheme == "content" && uri.authority == tree.authority &&
                            D.getTreeDocumentId(uri) == D.getTreeDocumentId(tree))
                        val a = resolver.openAssetFileDescriptor(uri, "r") ?: error("unavailable")
                        try {
                            Os.lseek(a.fileDescriptor, 0, OsConstants.SEEK_CUR)
                            val size = if (a.declaredLength >= 0) a.declaredLength else Os.fstat(a.fileDescriptor).st_size - a.startOffset
                            require(size >= 0 && a.startOffset >= 0)
                            val id = ++next; handles[id] = a
                            mapOf("handle" to id, "size" to size)
                        } catch (e: Exception) { a.close(); throw e }
                    }
                    "read" -> {
                        val a = handles[call.argument<Number>("handle")!!.toInt()] ?: error("closed")
                        val offset = call.argument<Number>("offset")!!.toLong()
                        val count = call.argument<Number>("count")!!.toInt()
                        require(offset >= 0 && count in 0..1048576 && offset <= Long.MAX_VALUE-a.startOffset-count)
                        val bytes = ByteArray(count); var done = 0
                        while(done < count) {
                            val n = Os.pread(a.fileDescriptor, bytes, done, count-done, a.startOffset+offset+done)
                            if(n <= 0) break
                            done += n
                        }
                        if(done == count) bytes else bytes.copyOf(done)
                    }
                    "close" -> { handles.remove((call.arguments as Number).toInt())?.close(); null }
                    else -> error("unsupported")
                }
                main.post { result.success(value) }
            } catch (_: Exception) { main.post { result.error("knowledge", "منبع خوانده نشد؛ مجوز پوشه یا خواندن تصادفی فایل را بررسی کنید. هیچ کپی ساخته نشد.", null) } }
        }
    } }
    private fun listTree(): Map<String, Any?> {
        val saved = prefs.getString("tree", null) ?: return mapOf("tree" to null, "files" to emptyList<Any>())
        val tree = Uri.parse(saved)
        val files = mutableListOf<Map<String, Any?>>()
        var visited = 0
        val seen = mutableSetOf<String>()
        fun scan(id: String, prefix: String, depth: Int) {
            require(depth <= 4 && seen.add(id))
            val children = D.buildChildDocumentsUriUsingTree(tree,id)
            resolver.query(children, arrayOf(D.Document.COLUMN_DOCUMENT_ID,D.Document.COLUMN_DISPLAY_NAME,
                D.Document.COLUMN_MIME_TYPE,D.Document.COLUMN_SIZE,D.Document.COLUMN_LAST_MODIFIED),null,null,null)?.use { c ->
                while(c.moveToNext()) {
                    require(++visited <= 1000)
                    val child = c.getString(0); val name = prefix+c.getString(1)
                    if(c.getString(2) == D.Document.MIME_TYPE_DIR) { scan(child,"$name/",depth+1); continue }
                    if(name.substringAfterLast('.',"").lowercase() !in setOf("zim","pdf","epub","docx","txt","md","markdown","rtf")) continue
                    files.add(mapOf("uri" to D.buildDocumentUriUsingTree(tree,child).toString(),
                        "name" to name,"size" to if(c.isNull(3)) -1L else c.getLong(3),"modified" to if(c.isNull(4)) 0L else c.getLong(4)))
                }
            } ?: error("folder unavailable")
        }
        scan(D.getTreeDocumentId(tree),"",0)
        return mapOf("tree" to saved,"files" to files)
    }
    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if(request != REQUEST) return false
        val result = picking ?: return true; picking = null
        if(code != Activity.RESULT_OK) { result.success(false); return true }
        try {
            val uri = data?.data ?: error("missing")
            require((data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0)
            resolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION)
            prefs.edit().putString("tree",uri.toString()).apply()
            result.success(true)
        } catch (_: Exception) { result.error("permission","مجوز پایدار فقط‌خواندنی دریافت نشد",null) }
        return true
    }
    fun close() {
        channel.setMethodCallHandler(null)
        picking?.error("picker","انتخاب پوشه لغو شد",null); picking = null
        worker.execute { closed = true; handles.values.forEach { it.close() }; handles.clear() }
        worker.shutdown()
    }
    companion object { const val REQUEST = 7460 }
}
