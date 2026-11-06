package vn.lumora.lumora

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * System notifications for events that arrive while the UI is not in the
 * foreground (messages, incoming calls, friend and remote-access requests).
 * Posted from Dart (AndroidBridge) over `lumora/service.notify`; Dart already
 * builds title/body in the app's language and drops muted chats.
 *
 * Channel names follow the app's language ([Lang]), not the phone's.
 */
object Notifier {
    private const val CH_MESSAGES = "lumora_messages"
    private const val CH_ALERTS = "lumora_alerts"

    /** Screen-share consent asked while Lumora was in the background. */
    const val SCREEN_CONSENT_ID = 1108

    /**
     * Creates the channels, or renames them (createNotificationChannel only
     * updates name/description of an existing channel; the user's importance
     * and sound choices are kept).
     */
    fun ensureChannels(ctx: Context, nm: NotificationManager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager) {
        if (Build.VERSION.SDK_INT < 26) return
        val l = Lang.context(ctx)
        try {
            nm.createNotificationChannel(
                NotificationChannel(CH_MESSAGES, l.getString(R.string.notif_ch_messages), NotificationManager.IMPORTANCE_HIGH)
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_ALERTS, l.getString(R.string.notif_ch_alerts), NotificationManager.IMPORTANCE_HIGH)
            )
        } catch (_: Throwable) {
        }
    }

    /** Brings the existing Lumora task to the front, like the launcher icon. */
    fun openAppIntent(ctx: Context): Intent =
        Intent(ctx, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    /** kind: message | call | remote | friend | reminder. [key] groups updates (e.g. one per conversation). */
    fun show(ctx: Context, kind: String, key: String, title: String, body: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannels(ctx, nm)
        val channel = if (kind == "message") CH_MESSAGES else CH_ALERTS
        val open = PendingIntent.getActivity(
            ctx, key.hashCode(),
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel)
        else @Suppress("DEPRECATION") Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
        val n = b.setSmallIcon(R.drawable.ic_stat_lumora)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(open)
            .setCategory(
                when (kind) {
                    "call", "remote" -> Notification.CATEGORY_CALL
                    "friend" -> Notification.CATEGORY_SOCIAL
                    "reminder" -> Notification.CATEGORY_REMINDER
                    else -> Notification.CATEGORY_MESSAGE
                }
            )
            .build()
        try {
            nm.notify(key.hashCode(), n)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted.
        }
    }

    /**
     * A remote session the user accepted needs screen-share consent, but
     * Android only shows the consent dialog over a visible Activity. Tapping
     * this brings Lumora to the front, where [MainActivity] asks right away.
     * Expires with the Dart-side timeout (the session is ended then).
     */
    fun showScreenConsent(ctx: Context, timeoutMs: Long) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannels(ctx, nm)
        val l = Lang.context(ctx)
        val open = PendingIntent.getActivity(
            ctx, SCREEN_CONSENT_ID,
            openAppIntent(ctx).putExtra(MainActivity.EXTRA_ASK_PROJECTION, true),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val body = l.getString(R.string.notif_consent_text)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CH_ALERTS).setTimeoutAfter(timeoutMs)
        else @Suppress("DEPRECATION") Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
        val n = b.setSmallIcon(R.drawable.ic_stat_lumora)
            .setContentTitle(l.getString(R.string.notif_consent))
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
        try {
            nm.notify(SCREEN_CONSENT_ID, n)
        } catch (_: SecurityException) {
        }
    }

    fun cancelScreenConsent(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(SCREEN_CONSENT_ID)
        } catch (_: Throwable) {
        }
    }

    fun cancelAll(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (s in nm.activeNotifications) {
            // The service notification stays; so does a pending screen-share
            // request (it is cancelled when the consent dialog opens).
            if (s.id != LumoraService.NOTIFICATION_ID && s.id != SCREEN_CONSENT_ID) nm.cancel(s.id)
        }
    }
}
