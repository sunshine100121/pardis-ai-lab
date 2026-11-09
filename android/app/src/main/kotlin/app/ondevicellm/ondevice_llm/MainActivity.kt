package app.ondevicellm.ondevice_llm

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.view.Display
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var offlineDictation: OfflineDictation? = null
    private var shareInbox: ShareInbox? = null
    private var scheduledPrompts: ScheduledPrompts? = null
    private var voiceAudio: VoiceAudio? = null
    private var displayManager: DisplayManager? = null
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = refreshDisplay(displayId)
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) = refreshDisplay(displayId)
    }
    override fun provideFlutterEngine(context: Context): FlutterEngine = PalaRuntime.obtain(this)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    @Deprecated("Activity result bridge for SAF")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (PalaRuntime.documents?.onResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        shareInbox?.offer(intent, notify = true)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == OfflineDictation.PERMISSION_REQUEST) {
            offlineDictation?.onPermissionResult(
                grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
        if (requestCode == VoiceAudio.PERMISSION_REQUEST) {
            voiceAudio?.onPermissionResult(
                grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
        if (requestCode == ScheduledPrompts.PERMISSION_REQUEST) {
            scheduledPrompts?.onPermissionResult(
                grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
    }

    override fun onStop() {
        offlineDictation?.cancel()
        // Not seen any more: the conversation's microphone and voice stop
        // (audit C7); the screen listens again when it comes back.
        voiceAudio?.pause()
        super.onStop()
    }

    override fun onDestroy() {
        displayManager?.unregisterDisplayListener(displayListener)
        offlineDictation?.close()
        offlineDictation = null
        voiceAudio?.close()
        voiceAudio = null
        super.onDestroy()
        PalaRuntime.detach(this)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayManager?.registerDisplayListener(displayListener, null)
        requestHighestRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        // Some OEM power modes reset the preference while the app is backgrounded.
        requestHighestRefreshRate()
        window.decorView.post { requestHighestRefreshRate() }
    }

    private fun refreshDisplay(displayId: Int) {
        val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else @Suppress("DEPRECATION") windowManager.defaultDisplay
        if (displayId == active?.displayId) requestHighestRefreshRate()
    }

    /// Samsung (and other) phones keep a Flutter app at 60 Hz unless it asks
    /// for a display mode. Pick the fastest mode at the current resolution
    /// (120 Hz on the S25+); the framework then renders at that cadence.
    private fun requestHighestRefreshRate() {
        val display: Display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else @Suppress("DEPRECATION") windowManager.defaultDisplay) ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        val attributes = window.attributes
        if (Build.VERSION.SDK_INT >= 35) window.setFrameRateBoostOnTouchEnabled(true)
        // A mode id is what the phone honours; a bare preferredRefreshRate was
        // not verified there.
        if (attributes.preferredDisplayModeId != best.modeId) {
            attributes.preferredDisplayModeId = best.modeId
            window.attributes = attributes
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        offlineDictation?.close()
        offlineDictation = OfflineDictation(this, flutterEngine.dartExecutor.binaryMessenger)
        shareInbox = ShareInbox(this, flutterEngine.dartExecutor.binaryMessenger).also {
            // The share that launched the app waits until Dart asks for it.
            it.offer(intent, notify = false)
        }
        scheduledPrompts = ScheduledPrompts(this, flutterEngine.dartExecutor.binaryMessenger)
        BackgroundDownloads(this, flutterEngine.dartExecutor.binaryMessenger)
        OnDeviceOcr(this, flutterEngine.dartExecutor.binaryMessenger)
        AudioDecode(flutterEngine.dartExecutor.binaryMessenger)
        PhoneActions(this, flutterEngine.dartExecutor.binaryMessenger)
        voiceAudio?.close()
        voiceAudio = VoiceAudio(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
