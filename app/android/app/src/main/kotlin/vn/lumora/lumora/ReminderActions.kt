package vn.lumora.lumora

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * "Hoãn 10 phút" on a reminder notification ([Notifier.show], kind "reminder").
 *
 * While Lumora runs (the cached Flutter engine with AndroidBridge attached),
 * Dart owns the snooze (lib/state/reminder_snooze.dart: banner, alarm sound,
 * notification again in 10 minutes, kept across restarts). When Dart cannot
 * take it, the snooze is done here: an alarm re-posts the same notification
 * ([FIRE]) in 10 minutes.
 */
class ReminderActions : BroadcastReceiver() {
    companion object {
        const val SNOOZE = "vn.lumora.REMINDER_SNOOZE"
        const val FIRE = "vn.lumora.REMINDER_FIRE"
        const val EXTRA_DATA = "reminder"
        const val EXTRA_KEY = "key"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_SOUND = "sound"
        const val EXTRA_VIBRATE = "vibrate"
        const val SNOOZE_MS = 10 * 60_000L

        /** Hands a reminder action to Dart; [fallback] runs if Dart cannot take it. Main thread. */
        fun toDart(action: String, data: String, fallback: () -> Unit) {
            val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
            if (engine == null) {
                fallback()
                return
            }
            MethodChannel(engine.dartExecutor.binaryMessenger, "lumora/service").invokeMethod(
                "reminderAction",
                mapOf("action" to action, "reminder" to data),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) fallback()
                    }

                    override fun error(code: String, message: String?, details: Any?) = fallback()
                    override fun notImplemented() = fallback()
                },
            )
        }
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        val key = intent.getStringExtra(EXTRA_KEY) ?: return
        val data = intent.getStringExtra(EXTRA_DATA) ?: return
        val app = ctx.applicationContext
        when (intent.action) {
            SNOOZE -> {
                Notifier.cancel(app, key)
                toDart("snooze", data) { scheduleNative(app, intent, key) }
            }
            FIRE -> Notifier.show(
                app, "reminder", key,
                intent.getStringExtra(EXTRA_TITLE) ?: "Lumora",
                intent.getStringExtra(EXTRA_BODY) ?: "",
                intent.getBooleanExtra(EXTRA_SOUND, true),
                intent.getBooleanExtra(EXTRA_VIBRATE, true),
                data,
            )
        }
    }

    private fun scheduleNative(ctx: Context, intent: Intent, key: String) {
        try {
            val fire = PendingIntent.getBroadcast(
                ctx, key.hashCode() + 2,
                Intent(intent).setClass(ctx, ReminderActions::class.java).setAction(FIRE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // inexact is fine for a snooze (no exact-alarm permission needed)
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + SNOOZE_MS, fire)
        } catch (_: Throwable) {
        }
    }
}
