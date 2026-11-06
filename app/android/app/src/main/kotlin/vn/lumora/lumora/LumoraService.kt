package vn.lumora.lumora

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.nio.ByteBuffer

/**
 * Foreground service that keeps the Lumora node (which lives in the app
 * process, inside liblumora_ffi.so) alive while the UI is in the background:
 * chats, incoming calls, file transfers and remote sessions keep working.
 *
 * It also
 *  - holds a [WifiManager.MulticastLock] so LAN discovery (UDP multicast)
 *    receives packets — Android filters multicast without it;
 *  - owns the MediaProjection screen capture while a remote-desktop host
 *    session is active (Android 14 requires a `mediaProjection` FGS);
 *  - runs the input pump that drains remote-control events from the core and
 *    hands them to [LumoraAccessibilityService].
 *
 * ## Foreground-service types (Android 14+ / targetSdk 34+)
 *
 * The type mask is recomputed whenever something changes ([refresh]) and
 * re-applied with `startForeground(id, n, mask)`:
 *
 *  - always `specialUse` (Android 14+; no type before 14). The persistent P2P
 *    connection is not a "data sync" (Android 15 stops `dataSync` after 6 h a
 *    day) and not `remoteMessaging` either: Play limits that type to handing
 *    text messages over between a user's own devices, while Lumora keeps a
 *    serverless connection open so friends can reach this phone at all (there
 *    is no push server to wake it). `specialUse` is the type Android reserves
 *    for such cases; the reason is given to reviewers in the manifest
 *    property `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`.
 *  - `phoneCall` + `microphone` while a call is connected or dialing
 *    ([setCall]); `camera` while the video-call camera runs ([CameraCapture]).
 *    Android 14 needs RECORD_AUDIO / CAMERA granted (and, for `phoneCall`,
 *    MANAGE_OWN_CALLS) *before* startForeground uses the type, and refuses
 *    camera/microphone types when the app is in the background. Each type is
 *    only added when its permission is granted, and on any refusal we retry
 *    with fewer types, ending with the base type, so the connection survives.
 *  - `mediaProjection` only after the user granted screen-capture consent
 *    (ACTION_PROJECTION carries the consent result), as Android 14 requires,
 *    and dropped as soon as capture stops.
 *
 * ## Google Play policy (must be done before each release that changes this)
 *
 *  - Play Console → App content → Foreground service permissions: declare
 *    every type listed in the manifest (specialUse, phoneCall, microphone,
 *    camera, mediaProjection), each with a short video showing the
 *    user-visible feature that needs it (background chats/calls reachable;
 *    an ongoing call with the screen off; a video call; remote support with
 *    screen sharing).
 *  - specialUse: reviewers read the subtype property; keep it accurate. If
 *    the declaration is rejected, the fallback is `remoteMessaging` (same
 *    code path: change [BASE_TYPE] and the manifest).
 *  - phoneCall: Play expects calling apps (ideally a self-managed
 *    `ConnectionService` / Telecom integration). Lumora is a VoIP app but does
 *    not use Telecom yet; if Play objects, set [USE_PHONE_CALL_TYPE] to false
 *    (and drop the type + FOREGROUND_SERVICE_PHONE_CALL from the manifest) —
 *    `microphone` (+ `camera`) alone keep calls working in the background.
 *  - mediaProjection: only used during a remote session the user accepted,
 *    after the system consent dialog.
 *
 * ## Timeouts
 *
 * Android 15 calls [onTimeout] when a time-limited type runs out. None of our
 * types is time-limited today, but if that ever happens (or a future type
 * is), the service stops itself cleanly and [MainActivity.onResume] starts it
 * again the next time the user opens Lumora ([wanted] stays true).
 */
class LumoraService : Service() {
    companion object {
        private const val TAG = "LumoraService"
        const val CHANNEL_ID = "lumora_connection"
        const val NOTIFICATION_ID = 1107
        const val ACTION_START = "vn.lumora.START"
        const val ACTION_STOP = "vn.lumora.STOP"
        const val ACTION_PROJECTION = "vn.lumora.PROJECTION"
        const val ACTION_STOP_PROJECTION = "vn.lumora.STOP_PROJECTION"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        /** See the class comment: false drops `phoneCall` (calls still use `microphone`). */
        private const val USE_PHONE_CALL_TYPE = true

        /** Base type of the persistent connection (Android 14+). */
        private val BASE_TYPE: Int
            get() = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0

        @Volatile var running = false
            private set

        /**
         * The app wants the service (set by [start], cleared by [stop]). When
         * the service could not start (app in the background) or was stopped
         * by a timeout, [MainActivity.onResume] starts it again.
         */
        @Volatile var wanted = false
            private set

        /** A call is connected or dialing (Dart: `lumora/service.setCall`). */
        @Volatile var inCall = false
            private set

        @Volatile private var instance: LumoraService? = null
        private val main = Handler(Looper.getMainLooper())

        fun start(ctx: Context) {
            wanted = true
            val i = Intent(ctx, LumoraService::class.java).setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (t: Throwable) {
                // e.g. ForegroundServiceStartNotAllowedException when started
                // from the background: MainActivity.onResume retries.
                Log.w(TAG, "cannot start foreground service: $t")
            }
        }

        fun stop(ctx: Context) {
            wanted = false
            if (!running) return
            try {
                ctx.startService(Intent(ctx, LumoraService::class.java).setAction(ACTION_STOP))
            } catch (t: Throwable) {
                Log.w(TAG, "cannot stop service: $t")
                main.post { instance?.shutdown() }
            }
        }

        /** Call state from Dart; adds/removes the call FGS types. */
        fun setCall(active: Boolean) {
            if (inCall == active) return
            inCall = active
            refresh()
        }

        /** Re-evaluates the FGS types and the notification (call, camera, projection, language changed). */
        fun refresh() {
            main.post { instance?.updateForeground() }
        }
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var capture: ScreenCapture? = null
    @Volatile private var pumpRunning = false
    private var pump: Thread? = null

    /** The type mask last accepted by startForeground (-1: not foreground yet). */
    private var currentTypes = -1
    /** Consent granted, capture about to start: `mediaProjection` may be used. */
    private var projectionGranted = false
    private var timedOut = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        instance = this
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wm.createMulticastLock("lumora-lan").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "multicast lock: $t")
        }
        startInputPump()
        // Tell the core the screen geometry up front: it reports it to the
        // viewer when a host session starts, before the first frame arrives.
        try {
            if (LumoraNative.available) {
                val (w, h, scale) = ScreenCapture.captureSize(this)
                LumoraNative.setDisplay(w, h, resources.displayMetrics.density * scale)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "setDisplay: $t")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                return START_NOT_STICKY
            }
            ACTION_PROJECTION -> {
                val code = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val data: Intent? = if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                else intent.getParcelableExtra(EXTRA_RESULT_DATA)
                // Android 14: the FGS must hold the mediaProjection type before
                // getMediaProjection(), and only after the user consented.
                projectionGranted = data != null
                updateForeground()
                val typed = Build.VERSION.SDK_INT < 29 ||
                    (currentTypes >= 0 && currentTypes and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION != 0)
                if (data != null && typed) {
                    startProjection(code, data)
                } else {
                    Log.w(TAG, "screen capture not started (consent=${data != null}, fgs type=$typed)")
                    projectionGranted = false
                    updateForeground()
                    ScreenCapture.reportStopped()
                }
            }
            ACTION_STOP_PROJECTION -> {
                stopProjection()
                updateForeground()
            }
            else -> updateForeground()
        }
        if (intent?.action == ACTION_START && !wanted) {
            // stop() raced a pending start: startForeground was honoured above
            // (required after startForegroundService), now leave.
            shutdown()
            return START_NOT_STICKY
        }
        if (currentTypes < 0) {
            // Android refused every type (see updateForeground): a started
            // foreground service that never calls startForeground crashes the app.
            shutdown()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopProjection()
        pumpRunning = false
        pump?.interrupt()
        try { multicastLock?.release() } catch (_: Throwable) {}
        running = false
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** Android 14 (`shortService` only) — kept for symmetry with the 15+ variant. */
    override fun onTimeout(startId: Int) {
        onFgsTimeout()
    }

    /** Android 15+: a time-limited FGS type ran out of time. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        onFgsTimeout()
    }

    private fun onFgsTimeout() {
        if (timedOut) return
        timedOut = true
        Log.w(TAG, "foreground service timed out; stopping until the app is opened again")
        // `wanted` stays true: MainActivity.onResume starts the service again.
        stopProjection()
        ScreenCapture.reportStopped()
        stopForegroundCompat()
        stopSelf()
    }

    private fun shutdown() {
        stopProjection()
        stopForegroundCompat()
        stopSelf()
    }

    // ------------------------------------------------------------ foreground types

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** Every type the current state needs (each only if its prerequisites hold). */
    private fun wantedTypes(): Int {
        if (Build.VERSION.SDK_INT < 29) return 0
        var t = BASE_TYPE
        if (capture != null || projectionGranted) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (inCall) {
            if (USE_PHONE_CALL_TYPE && (Build.VERSION.SDK_INT < 34 || granted(Manifest.permission.MANAGE_OWN_CALLS))) {
                t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            }
            if (Build.VERSION.SDK_INT >= 30 && granted(Manifest.permission.RECORD_AUDIO)) {
                t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
        }
        if (Build.VERSION.SDK_INT >= 30 && CameraCapture.running && granted(Manifest.permission.CAMERA)) {
            t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return t
    }

    private fun notificationKind() = when {
        capture != null || projectionGranted -> "sharing"
        inCall -> "call"
        else -> "connected"
    }

    /**
     * (Re-)enters the foreground with the types the state needs. If Android
     * refuses a type (missing runtime permission, camera/microphone while in
     * the background, …) it falls back to fewer types — the connection itself
     * must survive.
     */
    fun updateForeground() {
        if (timedOut) return
        val want = wantedTypes()
        val kind = notificationKind()
        val n = buildNotification(kind)
        if (Build.VERSION.SDK_INT < 29) {
            try {
                startForeground(NOTIFICATION_ID, n)
                currentTypes = 0
            } catch (t: Throwable) {
                Log.w(TAG, "startForeground failed: $t")
            }
            return
        }
        val attentionTypes = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
            (if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0)
        val candidates = linkedSetOf(
            want,
            want and (if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0).inv(),
            want and attentionTypes.inv(),
            BASE_TYPE,
        )
        for (types in candidates) {
            try {
                startForeground(NOTIFICATION_ID, n, types)
                if (types != want) Log.w(TAG, "foreground with reduced types 0x${types.toString(16)} (wanted 0x${want.toString(16)})")
                currentTypes = types
                return
            } catch (t: Throwable) {
                // SecurityException (permission / while-in-use), IllegalArgumentException
                // (type not in the manifest), ForegroundServiceStartNotAllowedException.
                Log.w(TAG, "startForeground(0x${types.toString(16)}) refused: $t")
            }
        }
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        currentTypes = -1
    }

    private fun buildNotification(kind: String): Notification {
        val l = Lang.context(this)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            // Created once; re-creating only renames it (language change).
            val ch = NotificationChannel(CHANNEL_ID, l.getString(R.string.notif_channel), NotificationManager.IMPORTANCE_MIN)
            ch.setShowBadge(false)
            try { nm.createNotificationChannel(ch) } catch (_: Throwable) {}
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val (title, text) = when (kind) {
            "sharing" -> R.string.notif_sharing to R.string.notif_sharing_text
            "call" -> R.string.notif_call to R.string.notif_call_text
            else -> R.string.notif_connected to R.string.notif_connected_text
        }
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        return b.setSmallIcon(R.drawable.ic_stat_lumora)
            .setContentTitle(l.getString(title))
            .setContentText(l.getString(text))
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .setCategory(if (kind == "call") Notification.CATEGORY_CALL else Notification.CATEGORY_SERVICE)
            .build()
    }

    // ------------------------------------------------------------ screen capture

    private fun startProjection(resultCode: Int, data: Intent) {
        stopProjection()
        projectionGranted = true
        if (!LumoraNative.available) {
            Log.w(TAG, "core built without media support: cannot share the screen")
            projectionGranted = false
            updateForeground()
            ScreenCapture.reportStopped()
            return
        }
        try {
            capture = ScreenCapture(this, resultCode, data) {
                // Stopped by the system or the user (status-bar chip, lock
                // screen, another app's projection): drop the type and tell
                // Dart, which ends the remote session(s).
                stopProjection()
                updateForeground()
                ScreenCapture.reportStopped()
            }.also { it.start() }
            ScreenCapture.active = true
        } catch (t: Throwable) {
            Log.e(TAG, "screen capture failed: $t")
            capture?.stop()
            capture = null
            projectionGranted = false
            updateForeground()
            ScreenCapture.reportStopped()
        }
    }

    private fun stopProjection() {
        capture?.stop()
        capture = null
        projectionGranted = false
        ScreenCapture.active = false
    }

    // ------------------------------------------------------------ remote input

    private fun startInputPump() {
        if (pump != null || !LumoraNative.available) return
        pumpRunning = true
        pump = Thread({
            val buf = ByteBuffer.allocateDirect(64 * 1024)
            val bytes = ByteArray(64 * 1024)
            while (pumpRunning) {
                val n = try { LumoraNative.nextInput(buf, 500) } catch (t: Throwable) { -1 }
                if (n < 0) break
                if (n == 0) continue
                buf.position(0)
                buf.get(bytes, 0, n)
                try {
                    val ev = JSONObject(String(bytes, 0, n, Charsets.UTF_8))
                    LumoraAccessibilityService.dispatch(this, ev)
                } catch (t: Throwable) {
                    Log.w(TAG, "bad input event: $t")
                }
            }
        }, "lumora-input").apply { isDaemon = true; start() }
    }
}
