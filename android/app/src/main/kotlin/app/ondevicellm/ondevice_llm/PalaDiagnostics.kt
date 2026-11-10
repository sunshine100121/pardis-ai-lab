package app.ondevicellm.ondevice_llm

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray

/** Content-free, bounded lifecycle timeline shared with Flutter diagnostics. */
internal object PalaDiagnostics {
    fun read(context: Context): String = context.getSharedPreferences("pala_diagnostics_v1", Context.MODE_PRIVATE).getString("events", "[]") ?: "[]"
    @Synchronized fun add(context: Context, event: String) {
        if (!event.matches(Regex("[a-zA-Z0-9._:-]{1,64}"))) return
        val prefs = context.getSharedPreferences("pala_diagnostics_v1", Context.MODE_PRIVATE)
        val rows = runCatching { JSONArray(prefs.getString("events", "[]")) }.getOrDefault(JSONArray())
        rows.put("${SystemClock.elapsedRealtime()}ms $event")
        val kept = JSONArray()
        for (i in maxOf(0, rows.length() - 300) until rows.length()) kept.put(rows.getString(i))
        prefs.edit().putString("events", kept.toString()).apply()
    }
}
