package app.ondevicellm.ondevice_llm

import android.Manifest
import android.content.pm.PackageManager
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One engine/model owner per process, retained by the host service across UI
 * destruction. No second isolate/model is loaded when the user returns. */
object PalaRuntime {
    private var engine: FlutterEngine? = null
    private var owner = 0L
    private var activity: MainActivity? = null
    var documents: PalaDocuments? = null
        private set
    private var discovery: HostDiscovery? = null
    private var channel: MethodChannel? = null
    var service: PalaHostService? = null
    private var starting: MethodChannel.Result? = null
    private var expectedServiceStop = false
    private var retained = false
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())

    fun obtain(a: MainActivity): FlutterEngine {
        PalaDiagnostics.add(a, "engine.obtain")
        activity = a
        engine?.let { documents?.activity = a; return it }
        val context = a.applicationContext
        appContext = context
        val e = FlutterEngine(context)
        PalaDiagnostics.add(context, "dart.engine.created")
        owner = NativeBridge.newOwner()
        engine = e
        documents = PalaDocuments(context, e.dartExecutor.binaryMessenger).also { it.activity = a }
        discovery = HostDiscovery(context, e.dartExecutor.binaryMessenger)
        MethodChannel(e.dartExecutor.binaryMessenger, "ondevice_llm/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeOwner" -> result.success(owner)
                "nativeLibrary" -> { (call.arguments as? String)?.let(NativeBridge::opened); result.success(null) }
                "memoryInfo" -> {
                    val m = ActivityManager.MemoryInfo()
                    (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(m)
                    result.success(mapOf("totalBytes" to m.totalMem, "availableBytes" to m.availMem, "lowMemory" to m.lowMemory))
                }
                "storageInfo" -> {
                    val s = StatFs((context.getExternalFilesDir(null) ?: context.filesDir).absolutePath)
                    result.success(mapOf("totalBytes" to s.totalBytes, "availableBytes" to s.availableBytes))
                }
                "powerInfo" -> {
                    val b = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    val p = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(mapOf("level" to b.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY), "charging" to b.isCharging,
                        "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) p.currentThermalStatus else -1))
                }
                "refreshRate" -> {
                    val a = activity
                    val d = if (Build.VERSION.SDK_INT >= 30) a?.display else @Suppress("DEPRECATION") a?.windowManager?.defaultDisplay
                    result.success(d?.refreshRate ?: 0f)
                }
                // Hosting never asks the window to remain lit.
                "keepScreenOn" -> result.success(null)
                else -> result.notImplemented()
            }
        }
        channel = MethodChannel(e.dartExecutor.binaryMessenger, "pala/hosting").also { c ->
            c.setMethodCallHandler { call, result ->
                when (call.method) {
                    "diagnosticEvent" -> { PalaDiagnostics.add(context, call.arguments as? String ?: "invalid.event"); result.success(null) }
                    "diagnosticRead" -> result.success(PalaDiagnostics.read(context))
                    "start" -> {
                        if (service != null && expectedServiceStop) result.error("host", "توقف سرور در حال تکمیل است؛ دوباره تلاش کنید", null)
                        else if (service != null) result.success(null)
                        else if (starting != null || activity == null) result.error("host", "سرور را از صفحه برنامه راه‌اندازی کنید", null)
                        else {
                            retained = true
                            starting = result
                            if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                activity?.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7404)
                            } else launchService()

                        }
                    }
                    "stop" -> { starting?.let { failStart("راه‌اندازی لغو شد") }; expectedServiceStop = true; service?.stopSelf(); retained = false; result.success(null); releaseIfIdle() }
                    "work" -> {
                        try {
                            if (call.arguments == true && service == null) error("سرویس سرور فعال نیست")
                            service?.work(call.arguments == true)
                            result.success(null)
                        } catch (e: Exception) { result.error("power", e.message, null) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return e
    }
    private fun launchService() {
        val pending = starting ?: return
        try {
            val context = appContext ?: error("Application unavailable")
            context.startForegroundService(Intent(context, PalaHostService::class.java))
            main.postDelayed({ if (starting === pending) failStart("اعلان سرویس راه‌اندازی نشد") }, 10000)
        } catch (e: Exception) { failStart("راه‌اندازی سرویس مجاز نبود") }
    }
    fun notificationPermission(granted: Boolean) {
        if (granted && activity != null) launchService()
        else failStart("برای وضعیت و توقف سرور، اعلان‌ها را در تنظیمات برنامه فعال کنید")
    }
    fun ready(s: PalaHostService): Boolean {
        PalaDiagnostics.add(s, "service.foreground.ready")
        if (!retained || engine == null) return false
        expectedServiceStop = false
        service = s; starting?.success(null); starting = null
        return true
    }
    fun failStart(message: String) {
        starting?.error("host", message, null); starting = null; retained = false; releaseIfIdle()
    }
    fun requestStop(reason: String) {
        channel?.invokeMethod("stop", reason, object : MethodChannel.Result {
            override fun success(result: Any?) { service?.stopSelf() }
            override fun error(code: String, message: String?, details: Any?) { service?.stopSelf() }
            override fun notImplemented() { service?.stopSelf() }
        })
    }
    fun serviceDestroyed(s: PalaHostService) {
        PalaDiagnostics.add(s, "service.runtime.destroyed")
        if (service === s) {
            service = null
            retained = false
            // Also cancels the Dart server if Android destroys the service.
            if (!expectedServiceStop) requestStop("سرویس اندروید متوقف شد")
            expectedServiceStop = false
            releaseIfIdle()
        }
    }
    fun detach(a: MainActivity) {
        PalaDiagnostics.add(a, "activity.detached")
        if (activity === a) { activity = null; documents?.detached(); if (starting != null && service == null) failStart("راه‌اندازی از صفحه برنامه لغو شد"); releaseIfIdle() }
    }
    private fun releaseIfIdle() {
        main.postDelayed({
            if (activity == null && !retained && service == null && starting == null) {
                val old = engine
                engine = null
                documents?.close(); documents = null
                discovery?.close(); discovery = null
                channel = null
                old?.destroy()
                appContext?.let { PalaDiagnostics.add(it, "dart.engine.destroyed") }
                if (old != null) NativeBridge.release(owner)
            }
        }, 1500)
    }
}
