package vn.lumora.lumora

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.FlutterInjector

/**
 * Call ringtone, outgoing ringback and the in-app message sound (Dart:
 * lib/platform/tones.dart → `lumora/service` ringStart / ringbackStart /
 * ringStop / ping). Main thread only (method channel + Notifier).
 *
 *  - Ringtone: the phone's own ringtone (USAGE_NOTIFICATION_RINGTONE) looping,
 *    plus a ring vibration pattern. Respects the ringer mode (silent: nothing,
 *    vibrate: vibration only) and Do Not Disturb (rings only when DND lets
 *    calls from anyone through, or the user let our call channel bypass it).
 *  - While the call notification rings by itself (the "incoming calls"
 *    channel: ringtone + vibration, FLAG_INSISTENT — posted while Lumora is in
 *    the background) nothing plays here, so it never rings twice. Cancelling
 *    that notification (call over, or Lumora came to the front and cleared
 *    it) silences it; if the call still rings, the ring continues here.
 *  - Ringback: Lumora's own tone (Flutter asset) on the in-call stream
 *    (USAGE_VOICE_COMMUNICATION_SIGNALLING), looping until stopped.
 *  - Message sound: the default notification sound + a short buzz, under
 *    the same ringer-mode / DND rules.
 */
object CallTones {
    private val main = Handler(Looper.getMainLooper())

    /** Dart wants the incoming call to ring. */
    var ringing = false
        private set
    private var sound = true
    private var vibrate = true

    /** The call notification on the ringtone channel is showing and ringing itself. */
    private var notificationRings = false

    private var ringtone: Ringtone? = null
    private var buzzing = false
    private var ringback: MediaPlayer? = null
    private var ringbackTone: ToneGenerator? = null
    private var pingTone: Ringtone? = null
    private var loopCheck: Runnable? = null

    /** MainActivity shows itself over the lock screen while a call rings. */
    var onRingingChanged: ((Boolean) -> Unit)? = null

    private val ringPattern = longArrayOf(0, 900, 700, 900, 1500)

    fun startRing(ctx: Context, sound: Boolean, vibrate: Boolean) {
        val app = ctx.applicationContext
        stopRingback()
        val changed = this.sound != sound || this.vibrate != vibrate
        this.sound = sound
        this.vibrate = vibrate
        if (ringing && !changed) return
        stopLocal(app)
        ringing = true
        if (!notificationRings) playLocal(app)
        onRingingChanged?.invoke(true)
    }

    /** Stops the ring (and its notification's sound), the ringback and their vibration. */
    fun stop(ctx: Context) {
        val app = ctx.applicationContext
        val wasRinging = ringing
        ringing = false
        stopLocal(app)
        stopRingback()
        if (notificationRings) {
            notificationRings = false
            Notifier.cancel(app, "call")
        }
        if (wasRinging) onRingingChanged?.invoke(false)
    }

    /** Notifier posted the call notification; [rings] = on the ringtone channel. */
    fun onCallNotification(ctx: Context, rings: Boolean) {
        notificationRings = rings
        if (rings) stopLocal(ctx.applicationContext)
    }

    /** The call notification was removed: keep ringing here if the call still rings. */
    fun onCallNotificationGone(ctx: Context) {
        if (!notificationRings) return
        notificationRings = false
        if (ringing && ringtone == null && !buzzing) playLocal(ctx.applicationContext)
    }

    // ------------------------------------------------------------------ ring

    private fun playLocal(ctx: Context) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = am.ringerMode
        if (!allowedByDnd(ctx, call = true)) return
        if (sound && mode == AudioManager.RINGER_MODE_NORMAL) {
            try {
                val r = RingtoneManager.getRingtone(ctx, Settings.System.DEFAULT_RINGTONE_URI)
                    ?: RingtoneManager.getRingtone(ctx, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
                if (r != null) {
                    r.audioAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    if (Build.VERSION.SDK_INT >= 28) r.isLooping = true
                    r.play()
                    ringtone = r
                    if (Build.VERSION.SDK_INT < 28) keepLooping(r)
                }
            } catch (_: Throwable) {
            }
        }
        if (vibrate && mode != AudioManager.RINGER_MODE_SILENT) {
            buzzing = vibrateWith(ctx, VibrationEffect.createWaveform(ringPattern, 1), AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
        }
    }

    /** Android 8–8.1 has no Ringtone.setLooping: restart it when it ends. */
    private fun keepLooping(r: Ringtone) {
        val check = object : Runnable {
            override fun run() {
                if (ringtone !== r) return
                try {
                    if (!r.isPlaying) r.play()
                } catch (_: Throwable) {
                }
                main.postDelayed(this, 1000)
            }
        }
        loopCheck = check
        main.postDelayed(check, 1000)
    }

    private fun stopLocal(ctx: Context) {
        loopCheck?.let { main.removeCallbacks(it) }
        loopCheck = null
        try {
            ringtone?.stop()
        } catch (_: Throwable) {
        }
        ringtone = null
        if (buzzing) {
            buzzing = false
            try {
                vibrator(ctx)?.cancel()
            } catch (_: Throwable) {
            }
        }
    }

    // -------------------------------------------------------------- ringback

    fun startRingback(ctx: Context, asset: String) {
        val app = ctx.applicationContext
        stop(app)
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        try {
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
            val mp = MediaPlayer()
            app.assets.openFd(key).use { fd -> mp.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length) }
            mp.setAudioAttributes(attrs)
            mp.isLooping = true
            mp.setOnPreparedListener { if (ringback === it) it.start() }
            mp.setOnErrorListener { p, _, _ ->
                if (ringback === p) stopRingback()
                true
            }
            ringback = mp
            mp.prepareAsync()
        } catch (_: Throwable) {
            stopRingback()
            // The asset could not be opened: the classic network ringback instead.
            try {
                ringbackTone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 60).also { it.startTone(ToneGenerator.TONE_SUP_RINGTONE) }
            } catch (_: Throwable) {
            }
        }
    }

    private fun stopRingback() {
        ringback?.let {
            ringback = null
            try {
                it.stop()
            } catch (_: Throwable) {
            }
            it.release()
        }
        ringbackTone?.let {
            ringbackTone = null
            try {
                it.stopTone()
                it.release()
            } catch (_: Throwable) {
            }
        }
    }

    // ----------------------------------------------------------------- ping

    /**
     * A one-shot alert (Lumora in front, or a notification on a silent channel):
     * [kind] message (the phone's notification sound), mention / reminder
     * (Lumora's own sounds, as on their notification channels).
     */
    fun ping(ctx: Context, kind: String, sound: Boolean, vibrate: Boolean) {
        val app = ctx.applicationContext
        if (ringing || !allowedByDnd(app, call = false, channel = channelOf(kind))) return
        val mode = (app.getSystemService(Context.AUDIO_SERVICE) as AudioManager).ringerMode
        if (sound && mode == AudioManager.RINGER_MODE_NORMAL) {
            try {
                val uri = when (kind) {
                    "mention" -> Notifier.rawSound(app, R.raw.lumora_mention)
                    "reminder" -> Notifier.rawSound(app, R.raw.lumora_reminder)
                    else -> Settings.System.DEFAULT_NOTIFICATION_URI
                }
                pingTone?.stop()
                pingTone = RingtoneManager.getRingtone(app, uri)?.also {
                    it.audioAttributes = AudioAttributes.Builder()
                        .setUsage(if (kind == "reminder") AudioAttributes.USAGE_NOTIFICATION_EVENT else AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    it.play()
                }
            } catch (_: Throwable) {
            }
        }
        if (vibrate && mode != AudioManager.RINGER_MODE_SILENT) {
            val pattern = if (kind == "reminder") longArrayOf(0, 300, 200, 300, 600, 300, 200, 300) else longArrayOf(0, 60, 90, 60)
            vibrateWith(app, VibrationEffect.createWaveform(pattern, -1), AudioAttributes.USAGE_NOTIFICATION)
        }
    }

    private fun channelOf(kind: String) = when (kind) {
        "mention" -> Notifier.CH_MENTIONS
        "reminder" -> Notifier.CH_REMINDERS
        else -> Notifier.CH_MESSAGES
    }

    // --------------------------------------------------------------- helpers

    /** Do Not Disturb lets this sound through (calls / messages from anyone, or our channel bypasses it). */
    private fun allowedByDnd(ctx: Context, call: Boolean, channel: String = if (call) Notifier.CH_CALLS else Notifier.CH_MESSAGES): Boolean {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return when (nm.currentInterruptionFilter) {
            NotificationManager.INTERRUPTION_FILTER_ALL, NotificationManager.INTERRUPTION_FILTER_UNKNOWN -> true
            NotificationManager.INTERRUPTION_FILTER_PRIORITY -> try {
                if (nm.getNotificationChannel(channel)?.canBypassDnd() == true) {
                    true
                } else {
                    val p = nm.notificationPolicy
                    val cat = if (call) NotificationManager.Policy.PRIORITY_CATEGORY_CALLS else NotificationManager.Policy.PRIORITY_CATEGORY_MESSAGES
                    val senders = if (call) p.priorityCallSenders else p.priorityMessageSenders
                    (p.priorityCategories and cat) != 0 && senders == NotificationManager.Policy.PRIORITY_SENDERS_ANY
                }
            } catch (_: Throwable) {
                false
            }
            else -> false
        }
    }

    private fun vibrator(ctx: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= 31) (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        else @Suppress("DEPRECATION") (ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)

    private fun vibrateWith(ctx: Context, effect: VibrationEffect, usage: Int): Boolean {
        return try {
            val v = vibrator(ctx) ?: return false
            if (!v.hasVibrator()) return false
            @Suppress("DEPRECATION")
            v.vibrate(effect, AudioAttributes.Builder().setUsage(usage).build())
            true
        } catch (_: Throwable) {
            false
        }
    }
}
