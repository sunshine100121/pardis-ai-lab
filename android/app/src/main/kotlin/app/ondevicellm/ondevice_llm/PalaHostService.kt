package app.ondevicellm.ondevice_llm

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Explicit, user-started local inference host. Never auto-starts on reboot or
 * after process death. specialUse rationale is declared in the manifest. */
class PalaHostService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var thermal: PowerManager.OnThermalStatusChangedListener? = null
    private var registered = false
    private val battery = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) { checkPower() }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        try {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                error("برای وضعیت و توقف سرور، اعلان‌ها را در تنظیمات برنامه فعال کنید")
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel("pala-host", "سرور محلی پالا", NotificationManager.IMPORTANCE_LOW))
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), flags)
            val stop = PendingIntent.getService(this, 1, Intent(this, PalaHostService::class.java).setAction("stop"), flags)
            val n = Notification.Builder(this, "pala-host").setSmallIcon(R.drawable.ic_stat_schedule)
                .setContentTitle("سرور محلی پالا فعال است")
                .setContentText("پاسخ‌گویی به دستگاه‌های جفت‌شده؛ نمایشگر می‌تواند خاموش باشد")
                .setContentIntent(open).setOngoing(true)
                .addAction(Notification.Action.Builder(null, "توقف سرور", stop).build()).build()
            if (Build.VERSION.SDK_INT >= 34) startForeground(7401, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            else startForeground(7401, n)
            val p = getSystemService(PowerManager::class.java)
            wake = p.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:inference").apply { setReferenceCounted(false) }
            PalaRuntime.ready(this)
            registerReceiver(battery, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            registered = true
            if (Build.VERSION.SDK_INT >= 29) {
                thermal = PowerManager.OnThermalStatusChangedListener { checkPower() }
                p.addThermalStatusListener(mainExecutor, thermal!!)
            }
            checkPower()
        } catch (e: Exception) { PalaRuntime.failStart(e.message ?: "سرویس راه‌اندازی نشد"); stopSelf() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") PalaRuntime.requestStop("سرور با فرمان کاربر متوقف شد")
        return START_NOT_STICKY
    }
    private fun checkPower() {
        val b = getSystemService(BatteryManager::class.java)
        val p = getSystemService(PowerManager::class.java)
        val level = b.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (!b.isCharging && level in 0..19) PalaRuntime.requestStop("باتری کمتر از ۲۰٪ و بدون شارژ")
        if (Build.VERSION.SDK_INT >= 29 && p.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE)
            PalaRuntime.requestStop("توقف ایمن به دلیل دمای بالا")
    }
    fun work(active: Boolean) {
        if (active) {
            checkPower()
            // Bounded to the server generation deadline, never held while idle.
            wake?.acquire(11 * 60 * 1000L)
        } else if (wake?.isHeld == true) wake?.release()
    }
    override fun onDestroy() {
        if (registered) unregisterReceiver(battery)
        if (Build.VERSION.SDK_INT >= 29) thermal?.let { getSystemService(PowerManager::class.java).removeThermalStatusListener(it) }
        work(false)
        PalaRuntime.serviceDestroyed(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
