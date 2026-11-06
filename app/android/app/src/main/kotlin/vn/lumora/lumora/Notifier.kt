package vn.lumora.lumora

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.content.LocusId
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall

/**
 * System notifications for events that arrive while the UI is not in the
 * foreground (messages, incoming calls, friend and remote-access requests).
 * Posted from Dart (AndroidBridge) over `lumora/service.notify`; Dart already
 * builds title/body in the app's language and drops muted chats.
 *
 * Channel names follow the app's language ([Lang]), not the phone's.
 */
object Notifier {
    /** Intent extra: the chat to open (notification, bubble, launcher shortcut). */
    const val EXTRA_CONV = "vn.lumora.CONV"
    /** Intent action of a chat opened from a notification / bubble / shortcut. */
    const val ACTION_OPEN_CONV = "vn.lumora.OPEN_CONV"

    /**
     * A message notification's chat (Android 11+ conversation: MessagingStyle,
     * a long-lived sharing shortcut with the person and their picture, and a
     * bubble). Absent when the content must stay hidden (app lock, locked chat).
     */
    data class Conversation(
        val conv: String,
        /** Who wrote this message (shown per line). */
        val sender: String,
        /** The chat's name: the person (direct chat) or the group. */
        val title: String,
        val group: Boolean,
        val avatar: ByteArray?,
        val bubble: Boolean,
        val time: Long,
    ) {
        companion object {
            fun from(call: MethodCall): Conversation? {
                val conv = call.argument<String>("conv")?.takeIf { it.isNotEmpty() } ?: return null
                val sender = call.argument<String>("sender") ?: ""
                return Conversation(
                    conv = conv,
                    sender = sender,
                    title = call.argument<String>("convTitle")?.takeIf { it.isNotEmpty() } ?: sender,
                    group = call.argument<Boolean>("group") ?: false,
                    avatar = call.argument<ByteArray>("avatar"),
                    bubble = call.argument<Boolean>("bubble") ?: true,
                    time = (call.argument<Number>("ts"))?.toLong()?.takeIf { it > 0 } ?: System.currentTimeMillis(),
                )
            }
        }
    }

    private data class Line(val sender: String, val text: CharSequence, val time: Long)

    /** The last lines of each chat's notification (MessagingStyle shows them all). */
    private val history = HashMap<String, ArrayDeque<Line>>()
    private const val HISTORY = 6

    const val CH_MESSAGES = "lumora_messages"
    private const val CH_MESSAGES_QUIET = "lumora_messages_quiet"
    private const val CH_ALERTS = "lumora_alerts"
    /** Incoming calls: the phone's ringtone + ring vibration (Settings sounds on). */
    const val CH_CALLS = "lumora_calls"
    /** Incoming calls without sound / vibration from the channel (CallTones plays what the settings allow). */
    private const val CH_CALLS_QUIET = "lumora_calls_quiet"

    /** @mentions of me: Lumora's own brighter sound (res/raw/lumora_mention.wav). */
    const val CH_MENTIONS = "lumora_mentions"
    private const val CH_MENTIONS_QUIET = "lumora_mentions_quiet"
    /** Reminders that are due: Lumora's reminder alarm (res/raw/lumora_reminder.wav). */
    const val CH_REMINDERS = "lumora_reminders"
    private const val CH_REMINDERS_QUIET = "lumora_reminders_quiet"

    private val callVibration = longArrayOf(0, 900, 700, 900, 1500)
    private val reminderVibration = longArrayOf(0, 300, 200, 300, 600, 300, 200, 300)

    /** Our own sounds, packaged as raw resources (branding/tools/make_sounds.py). */
    fun rawSound(ctx: Context, res: Int): android.net.Uri =
        android.net.Uri.parse("android.resource://${ctx.packageName}/$res")

    private fun sonification(usage: Int): AudioAttributes =
        AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()

    private fun quiet(id: String, name: String) =
        NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(null, null)
            enableVibration(false)
        }

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
            // default notification sound (the channel default) + vibration
            nm.createNotificationChannel(
                NotificationChannel(CH_MESSAGES, l.getString(R.string.notif_ch_messages), NotificationManager.IMPORTANCE_HIGH).apply {
                    enableVibration(true)
                }
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_MESSAGES_QUIET, l.getString(R.string.notif_ch_messages_quiet), NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(null, null)
                    enableVibration(false)
                }
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_ALERTS, l.getString(R.string.notif_ch_alerts), NotificationManager.IMPORTANCE_HIGH)
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_CALLS, l.getString(R.string.notif_ch_calls), NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(
                        Settings.System.DEFAULT_RINGTONE_URI,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    enableVibration(true)
                    vibrationPattern = callVibration
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC // the text is already privacy-filtered by Dart
                }
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_MENTIONS, l.getString(R.string.notif_ch_mentions), NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(rawSound(ctx, R.raw.lumora_mention), sonification(AudioAttributes.USAGE_NOTIFICATION))
                    enableVibration(true)
                }
            )
            nm.createNotificationChannel(quiet(CH_MENTIONS_QUIET, l.getString(R.string.notif_ch_mentions_quiet)))
            nm.createNotificationChannel(
                NotificationChannel(CH_REMINDERS, l.getString(R.string.notif_ch_reminders), NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(rawSound(ctx, R.raw.lumora_reminder), sonification(AudioAttributes.USAGE_NOTIFICATION_EVENT))
                    enableVibration(true)
                    vibrationPattern = reminderVibration
                }
            )
            nm.createNotificationChannel(quiet(CH_REMINDERS_QUIET, l.getString(R.string.notif_ch_reminders_quiet)))
            nm.createNotificationChannel(
                NotificationChannel(CH_CALLS_QUIET, l.getString(R.string.notif_ch_calls_quiet), NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
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

    /**
     * kind: message | call | remote | friend | reminder. [key] groups updates (e.g. one per conversation).
     * [sound] / [vibrate] (messages and calls; Settings › Notifications): with both on, the
     * channel's own sound and vibration are used (ringtone for calls, notification sound for
     * messages); otherwise a silent channel, and [CallTones] plays only what is allowed.
     */
    fun show(
        ctx: Context, kind: String, key: String, title: String, body: String,
        sound: Boolean = true, vibrate: Boolean = true, reminder: String? = null,
        conversation: Conversation? = null,
        callId: String? = null,
    ) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannels(ctx, nm)
        val full = sound && vibrate
        val channel = when (kind) {
            "message" -> if (full) CH_MESSAGES else CH_MESSAGES_QUIET
            "mention" -> if (full) CH_MENTIONS else CH_MENTIONS_QUIET
            "reminder" -> if (full) CH_REMINDERS else CH_REMINDERS_QUIET
            "call" -> if (full) CH_CALLS else CH_CALLS_QUIET
            else -> CH_ALERTS
        }
        val call = kind == "call"
        val chat = conversation?.takeIf { kind == "message" || kind == "mention" }
        val open = PendingIntent.getActivity(
            ctx, key.hashCode(),
            Intent(ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_INCOMING_CALL, call)
                .also { if (chat != null) it.setAction(ACTION_OPEN_CONV).putExtra(EXTRA_CONV, chat.conv) },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel)
        else @Suppress("DEPRECATION") Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
        if (call) {
            // Rings until answered / declined / over (Dart cancels "call" then); full screen
            // over the lock screen where Android allows it (USE_FULL_SCREEN_INTENT).
            b.setOngoing(true)
                .setFullScreenIntent(open, true)
                .setTimeoutAfter(90_000)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            addCallButtons(ctx, b, title, callId ?: "")
        }
        if (kind == "reminder" && reminder != null) {
            // "Hoãn 10 phút" (ReminderActions: back to Dart, or natively if Lumora is not running)
            // and "Mở" (opens Lumora on the chat).
            val l = Lang.context(ctx)
            val id = key.hashCode()
            val snooze = PendingIntent.getBroadcast(
                ctx, id,
                Intent(ctx, ReminderActions::class.java).setAction(ReminderActions.SNOOZE)
                    .putExtra(ReminderActions.EXTRA_DATA, reminder).putExtra(ReminderActions.EXTRA_KEY, key)
                    .putExtra(ReminderActions.EXTRA_TITLE, title).putExtra(ReminderActions.EXTRA_BODY, body)
                    .putExtra(ReminderActions.EXTRA_SOUND, sound).putExtra(ReminderActions.EXTRA_VIBRATE, vibrate),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val openChat = PendingIntent.getActivity(
                ctx, id + 1,
                Intent(ctx, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(MainActivity.EXTRA_REMINDER_OPEN, reminder).putExtra(ReminderActions.EXTRA_KEY, key),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(null, l.getString(R.string.notif_reminder_snooze), snooze).build())
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(null, l.getString(R.string.notif_reminder_open), openChat).build())
            b.setContentIntent(openChat)
        }
        b.setSmallIcon(R.drawable.ic_stat_lumora)
            .setContentTitle(title)
            .setContentText(body)
        if (!(call && Build.VERSION.SDK_INT >= 31)) b.setStyle(Notification.BigTextStyle().bigText(body)) // CallStyle set above
        if (chat != null && Build.VERSION.SDK_INT >= 28) {
            try {
                styleConversation(ctx, b, chat, body)
            } catch (t: Throwable) {
                android.util.Log.w("Notifier", "conversation style: $t") // plain notification then
            }
        }
        val n = b
            .setAutoCancel(!call)
            .also { if (kind != "reminder" || reminder == null) it.setContentIntent(open) }
            .setCategory(
                when (kind) {
                    "call", "remote" -> Notification.CATEGORY_CALL
                    "friend" -> Notification.CATEGORY_SOCIAL
                    "reminder" -> Notification.CATEGORY_REMINDER
                    else -> Notification.CATEGORY_MESSAGE
                }
            )
            .build()
        if (call && full) n.flags = n.flags or Notification.FLAG_INSISTENT // loop the ringtone
        try {
            nm.notify(key.hashCode(), n)
            // (notifications or the channel turned off by the user: it does not ring)
            val shown = nm.areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < 26 || nm.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE)
            if (call) CallTones.onCallNotification(ctx, rings = full && shown)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted: CallTones keeps ringing in-app.
        }
        // A silent channel: the part of the alert the settings still allow.
        if (kind in listOf("message", "mention", "reminder") && !full && (sound || vibrate)) CallTones.ping(ctx, kind, sound, vibrate)
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

    // ------------------------------------------------------------ incoming call

    /**
     * Answer / Decline on the ringing notification: Android 12+ CallStyle
     * (the system's call layout, green/red buttons), plain actions before.
     * Answer opens Lumora on the call (MainActivity answers through Dart once
     * it is in front: microphone permission, call screen); Decline is handled
     * without opening anything ([CallActions]).
     */
    private fun addCallButtons(ctx: Context, b: Notification.Builder, caller: String, callId: String) {
        val l = Lang.context(ctx)
        val answer = PendingIntent.getActivity(
            ctx, 1201,
            openAppIntent(ctx)
                .putExtra(MainActivity.EXTRA_INCOMING_CALL, true)
                .putExtra(MainActivity.EXTRA_CALL_ACTION, "answer")
                .putExtra(CallActions.EXTRA_CALL_ID, callId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val decline = PendingIntent.getBroadcast(
            ctx, 1202,
            Intent(ctx, CallActions::class.java).setAction(CallActions.DECLINE).putExtra(CallActions.EXTRA_CALL_ID, callId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (Build.VERSION.SDK_INT >= 31) {
            val person = android.app.Person.Builder().setName(caller.ifEmpty { "Lumora" }).setImportant(true).build()
            b.setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer))
        } else {
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(null, l.getString(R.string.notif_call_decline), decline).build())
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(null, l.getString(R.string.notif_call_answer), answer).build())
        }
    }

    // ------------------------------------------------------------ conversations

    private fun shortcutId(conv: String) = "conv:$conv"

    /**
     * MessagingStyle with the person (name + picture), the chat's long-lived
     * shortcut (Android 11 lists it under "Conversations": priority, bubbles,
     * per-chat sound) and, unless turned off in Lumora, its bubble.
     */
    @android.annotation.TargetApi(28)
    private fun styleConversation(ctx: Context, b: Notification.Builder, c: Conversation, body: String) {
        val l = Lang.context(ctx)
        // the writer's picture (in a group, [avatar] is the group's: the writer gets a letter)
        val icon = Icon.createWithBitmap(avatarBitmap(if (c.group) null else c.avatar, c.sender.ifEmpty { c.title }))
        val sender = android.app.Person.Builder().setName(c.sender.ifEmpty { c.title }).setIcon(icon).setKey(c.conv + "/" + c.sender).build()
        val me = android.app.Person.Builder().setName(l.getString(R.string.notif_me)).build()
        val lines = synchronized(history) {
            val q = history.getOrPut(c.conv) { ArrayDeque() }
            q.addLast(Line(c.sender, body, c.time))
            while (q.size > HISTORY) q.removeFirst()
            q.toList()
        }
        val style = Notification.MessagingStyle(me)
        if (c.group) {
            style.setConversationTitle(c.title)
            style.setGroupConversation(true)
        }
        for (line in lines) {
            val p = if (line.sender == c.sender) sender
            else android.app.Person.Builder().setName(line.sender.ifEmpty { c.title }).setKey(c.conv + "/" + line.sender).build()
            style.addMessage(Notification.MessagingStyle.Message(line.text, line.time, p))
        }
        b.setStyle(style).setWhen(c.time).setShowWhen(true)
        if (!c.group) b.setLargeIcon(icon)
        if (Build.VERSION.SDK_INT < 30) return
        // Android 11+: a conversation (long-lived shortcut) and its bubble
        val chatIcon = Icon.createWithAdaptiveBitmap(adaptive(avatarBitmap(c.avatar, c.title)))
        val openChat = Intent(ctx, MainActivity::class.java)
            .setAction(ACTION_OPEN_CONV)
            .putExtra(EXTRA_CONV, c.conv)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val id = shortcutId(c.conv)
        val shortcut = ShortcutInfo.Builder(ctx, id)
            .setShortLabel(c.title.ifEmpty { "Lumora" })
            .setLongLived(true)
            .setIcon(chatIcon)
            .setIntent(openChat)
            .setLocusId(LocusId(id))
            .setCategories(setOf("vn.lumora.category.CHAT"))
            .also { if (!c.group) it.setPerson(sender) }
            .build()
        ctx.getSystemService(ShortcutManager::class.java)?.pushDynamicShortcut(shortcut)
        b.setShortcutId(id).setLocusId(LocusId(id))
        if (c.bubble) {
            // The bubble shows the chat in [BubbleActivity] (the same Lumora UI, opened on this chat).
            val bubbleIntent = PendingIntent.getActivity(
                ctx, id.hashCode(),
                Intent(ctx, BubbleActivity::class.java).setAction(ACTION_OPEN_CONV).putExtra(EXTRA_CONV, c.conv)
                    .setData(android.net.Uri.fromParts("lumora-conv", c.conv, null)),
                // Android 12+: a bubble's intent must be mutable
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            b.setBubbleMetadata(
                Notification.BubbleMetadata.Builder(bubbleIntent, chatIcon)
                    .setDesiredHeight(640)
                    .setAutoExpandBubble(false)
                    .setSuppressNotification(false)
                    .build()
            )
        } else {
            b.setBubbleMetadata(null)
        }
    }

    /** A round picture: the avatar, or the name's first letter on a colour from the name. */
    private fun avatarBitmap(bytes: ByteArray?, name: String): Bitmap {
        val size = 192
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val cv = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val src = bytes?.let { try { BitmapFactory.decodeByteArray(it, 0, it.size) } catch (_: Throwable) { null } }
        val clip = Path().apply { addCircle(size / 2f, size / 2f, size / 2f, Path.Direction.CW) }
        cv.clipPath(clip)
        if (src != null) {
            val side = minOf(src.width, src.height)
            val r = Rect((src.width - side) / 2, (src.height - side) / 2, (src.width + side) / 2, (src.height + side) / 2)
            cv.drawBitmap(src, r, Rect(0, 0, size, size), paint)
        } else {
            val palette = intArrayOf(0xFF6366F1.toInt(), 0xFF0EA5E9.toInt(), 0xFF10B981.toInt(), 0xFFF59E0B.toInt(), 0xFFEF4444.toInt(), 0xFFEC4899.toInt(), 0xFF8B5CF6.toInt())
            paint.color = palette[Math.floorMod(name.hashCode(), palette.size)]
            cv.drawRect(0f, 0f, size.toFloat(), size.toFloat(), paint)
            val letter = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "L"
            paint.color = 0xFFFFFFFF.toInt()
            paint.textSize = size * 0.45f
            paint.textAlign = Paint.Align.CENTER
            paint.isFakeBoldText = true
            val y = size / 2f - (paint.descent() + paint.ascent()) / 2f
            cv.drawText(letter, size / 2f, y, paint)
        }
        return out
    }

    /** Adaptive icons are cropped to the inner 72/108: pad the picture so the whole circle shows. */
    private fun adaptive(src: Bitmap): Bitmap {
        val size = 288
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val inner = (size * 72f / 108f).toInt()
        val off = (size - inner) / 2
        Canvas(out).drawBitmap(src, null, Rect(off, off, off + inner, off + inner), Paint(Paint.FILTER_BITMAP_FLAG))
        return out
    }

    private fun isBubble(n: Notification) = Build.VERSION.SDK_INT >= 30 && (n.flags and Notification.FLAG_BUBBLE) != 0

    /** Read: the bubble stays on screen, its notification leaves the shade (no new alert). */
    private fun keepBubbleOnly(ctx: Context, nm: NotificationManager, sbn: android.service.notification.StatusBarNotification) {
        if (Build.VERSION.SDK_INT < 30) return
        val meta = sbn.notification.bubbleMetadata
        val pi = meta?.intent
        val icon = meta?.icon
        if (pi == null || icon == null) {
            nm.cancel(sbn.id)
            return
        }
        try {
            val b = Notification.Builder.recoverBuilder(ctx, sbn.notification)
                .setOnlyAlertOnce(true)
                .setBubbleMetadata(
                    Notification.BubbleMetadata.Builder(pi, icon)
                        .setDesiredHeight(meta.desiredHeight.takeIf { it > 0 } ?: 640)
                        .setSuppressNotification(true)
                        .build()
                )
            nm.notify(sbn.id, b.build())
        } catch (_: Throwable) {
            nm.cancel(sbn.id)
        }
    }

    /**
     * Drops the chats' shortcuts (and their bubbles/notifications): a chat
     * deleted or locked, or notification content hidden (null = every chat).
     */
    fun forgetConversations(ctx: Context, convs: List<String>?) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val sm = ctx.getSystemService(ShortcutManager::class.java)
                val ids = convs?.map(::shortcutId) ?: sm.dynamicShortcuts.map { it.id }.filter { it.startsWith("conv:") }
                if (ids.isNotEmpty()) {
                    sm.removeLongLivedShortcuts(ids)
                    sm.removeDynamicShortcuts(ids)
                }
            } catch (_: Throwable) {
            }
        }
        val list = convs ?: synchronized(history) { history.keys.toList() }
        for (c in list) {
            synchronized(history) { history.remove(c) }
            try { nm.cancel(c.hashCode()) } catch (_: Throwable) {}
        }
    }

    /** Removes the notification posted under [key] (call over, chat read elsewhere). */
    fun cancel(ctx: Context, key: String) {
        synchronized(history) { history.remove(key) }
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val bubble = nm.activeNotifications.firstOrNull { it.id == key.hashCode() && isBubble(it.notification) }
            if (bubble != null) keepBubbleOnly(ctx, nm, bubble) else nm.cancel(key.hashCode())
        } catch (_: Throwable) {
        }
        // (its ringtone stopped with it; a call still ringing goes on in-app)
        if (key == "call") CallTones.onCallNotificationGone(ctx)
    }

    fun cancelAll(ctx: Context) {
        synchronized(history) { history.clear() }
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (s in nm.activeNotifications) {
            // The service notification stays; so does a pending screen-share
            // request (it is cancelled when the consent dialog opens).
            if (s.id == LumoraService.NOTIFICATION_ID || s.id == SCREEN_CONSENT_ID) continue
            // a chat open as a bubble stays a bubble (only its shade entry goes)
            if (isBubble(s.notification)) keepBubbleOnly(ctx, nm, s) else nm.cancel(s.id)
        }
        CallTones.onCallNotificationGone(ctx)
    }
}
