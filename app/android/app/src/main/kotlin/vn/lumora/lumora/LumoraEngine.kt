package vn.lumora.lumora

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine of the process (Dart UI + stores + AndroidBridge).
 *
 * Created by whichever comes first: [MainActivity] (the user opened Lumora) or
 * [LumoraService] when Android restarts it on its own — after Lumora was
 * swiped away and the process killed (MIUI/HyperOS and other OEMs do that
 * even with a foreground service), START_STICKY / the restart alarm brings the
 * service back without any Activity. Running the normal Dart entry point
 * headless then boots the session as usual (the core starts; a
 * password-protected install waits on its lock screen), so messages and calls
 * reach this phone and are notified again. An Activity opened later attaches
 * to this same engine (no second Dart, no second start of the core).
 *
 * `lumora/service` is registered here, not in the Activity, so notifications
 * keep working while no Activity exists.
 */
object LumoraEngine {
    private const val TAG = "LumoraEngine"
    const val ENGINE_ID = "lumora_main"

    private val main = Handler(Looper.getMainLooper())

    /** The cached engine, created (and its Dart entry point run) if needed. Main thread. */
    fun obtain(ctx: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val app = ctx.applicationContext
        val engine = FlutterEngine(app)
        LumoraNative.init(app)
        registerService(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    /** Service side: make sure Dart (and so the core) runs, without any UI. */
    fun ensureRunning(ctx: Context) {
        val app = ctx.applicationContext
        main.post {
            if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) return@post
            try {
                Log.i(TAG, "starting Lumora in the background (no Activity)")
                obtain(app)
            } catch (t: Throwable) {
                Log.w(TAG, "background engine: $t")
            }
        }
    }

    fun channel(): MethodChannel? =
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { MethodChannel(it.dartExecutor.binaryMessenger, "lumora/service") }

    // ------------------------------------------------------------ open a chat

    /** A chat to open (notification / bubble / shortcut tap) that Dart has not taken yet. */
    @Volatile private var pendingConv: String? = null

    /**
     * Opens chat [conv] in the Dart UI (notification, bubble or launcher
     * shortcut). Kept until Dart confirms; Dart also asks for it when it
     * attaches (`takeOpenConv`), for a cold start.
     */
    fun openConv(conv: String) {
        pendingConv = conv
        main.post {
            val ch = channel() ?: return@post
            ch.invokeMethod("openConv", mapOf("conv" to conv), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true && pendingConv == conv) pendingConv = null
                }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    /** A call answer/decline from the notification that Dart has not taken yet: (action, call id). */
    @Volatile private var pendingCall: Pair<String, String>? = null

    /** Answer / Decline on the incoming-call notification → Dart (kept until Dart confirms). */
    fun callAction(action: String, callId: String) {
        val a = action to callId
        pendingCall = a
        main.post {
            val ch = channel() ?: return@post
            ch.invokeMethod("callAction", mapOf("action" to action, "callId" to callId), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true && pendingCall == a) pendingCall = null
                }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    fun takeCallAction(): Map<String, String>? {
        val a = pendingCall ?: return null
        pendingCall = null
        return mapOf("action" to a.first, "callId" to a.second)
    }

    fun takeOpenConv(): String? {
        val c = pendingConv
        pendingConv = null
        return c
    }

    /** The chat an Intent asks to open (notification / bubble / shortcut), if any. */
    fun convOf(intent: Intent?): String? =
        intent?.getStringExtra(Notifier.EXTRA_CONV)?.takeIf { it.isNotEmpty() }

    // ------------------------------------------------------------ lumora/service

    private fun registerService(app: Context, engine: FlutterEngine) {
        // Dart asks once at start-up, maybe before any Activity exists (headless start)
        MethodChannel(engine.dartExecutor.binaryMessenger, "lumora/links").setMethodCallHandler { call, result ->
            if (call.method == "ready") result.success(MainActivity.takeQueuedLinks()) else result.notImplemented()
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "lumora/service").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> { LumoraService.start(app); result.success(true) }
                "stop" -> { LumoraService.stop(app); result.success(true) }
                "setLanguage" -> {
                    if (Lang.set(app, call.argument<String>("lang"))) {
                        Notifier.ensureChannels(app)
                        LumoraService.refresh()
                    }
                    result.success(true)
                }
                "setCall" -> {
                    LumoraService.setCall(call.argument<Boolean>("active") ?: false)
                    result.success(true)
                }
                // a video call is live: leaving Lumora (Home, Recents) shows it picture-in-picture
                "setPip" -> {
                    MainActivity.setPipWanted(call.argument<Boolean>("on") ?: false)
                    result.success(true)
                }
                "notify" -> {
                    Notifier.show(
                        app,
                        call.argument<String>("kind") ?: "message",
                        call.argument<String>("key") ?: "lumora",
                        call.argument<String>("title") ?: "Lumora",
                        call.argument<String>("body") ?: "",
                        call.argument<Boolean>("sound") ?: true,
                        call.argument<Boolean>("vibrate") ?: true,
                        call.argument<String>("reminder"),
                        Notifier.Conversation.from(call),
                        call.argument<String>("callId"),
                    )
                    result.success(true)
                }
                "forgetConversations" -> {
                    Notifier.forgetConversations(app, call.argument<List<String>>("convs"))
                    result.success(true)
                }
                "takeOpenConv" -> result.success(takeOpenConv())
                "takeCallAction" -> result.success(takeCallAction())
                "setSecure" -> {
                    MainActivity.setSecure(call.argument<Boolean>("on") ?: false)
                    result.success(true)
                }
                "setRecentsHidden" -> {
                    MainActivity.setRecentsHidden(call.argument<Boolean>("on") ?: false)
                    result.success(true)
                }
                "ringStart" -> {
                    CallTones.startRing(app, call.argument<Boolean>("sound") ?: true, call.argument<Boolean>("vibrate") ?: true)
                    result.success(true)
                }
                "ringbackStart" -> {
                    CallTones.startRingback(app, call.argument<String>("asset") ?: "assets/sounds/ringback.wav")
                    result.success(true)
                }
                "ringStop" -> { CallTones.stop(app); result.success(true) }
                "ping" -> {
                    CallTones.ping(
                        app, call.argument<String>("kind") ?: "message",
                        call.argument<Boolean>("sound") ?: true, call.argument<Boolean>("vibrate") ?: true,
                    )
                    result.success(true)
                }
                "clearNotifications" -> { Notifier.cancelAll(app); result.success(true) }
                "cancelNotification" -> { Notifier.cancel(app, call.argument<String>("key") ?: ""); result.success(true) }
                "background" -> result.success(Background.status(app))
                "requestIgnoreBattery" -> result.success(Background.requestIgnoreBattery(MainActivity.current() ?: app))
                "openAutostart" -> result.success(Background.openAutostart(MainActivity.current() ?: app))
                "networkInfo" -> result.success(networkInfo(app))
                "info" -> result.success(mapOf(
                    "sdk" to Build.VERSION.SDK_INT,
                    "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
                    "media" to LumoraNative.available,
                    "service" to LumoraService.running,
                ))
                else -> result.notImplemented()
            }
        }
    }

    /** The active network for the automatic-download limits: Wi-Fi / mobile data / roaming
     *  (or a Wi-Fi the system reports as metered, e.g. a phone hotspot). */
    private fun networkInfo(ctx: Context): Map<String, Any> {
        return try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return mapOf("online" to false)
            val n = cm.activeNetwork ?: return mapOf("online" to false)
            val caps = cm.getNetworkCapabilities(n) ?: return mapOf("online" to false)
            val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            val cell = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            val roaming = Build.VERSION.SDK_INT >= 28 && !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING)
            val metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) &&
                (Build.VERSION.SDK_INT < 30 || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED))
            mapOf("online" to true, "wifi" to wifi, "cell" to cell, "roaming" to roaming, "metered" to metered)
        } catch (e: Exception) {
            mapOf("online" to false)
        }
    }
}
