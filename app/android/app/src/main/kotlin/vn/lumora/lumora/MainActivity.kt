package vn.lumora.lumora

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Hosts the Flutter UI and exposes the Android-only pieces over method channels:
 *
 *  - `lumora/service`: start/stop the foreground service (keeps the node alive,
 *    holds the Wi-Fi multicast lock), `info`, `setSecure` (FLAG_SECURE: no
 *    screenshots, blank preview in recent apps), `setLanguage {lang}` (app
 *    language for notifications), `setCall {active}` (call FGS types).
 *  - `lumora/screen`: `start` asks for MediaProjection consent and starts
 *    pushing frames into the core (in the background it brings Lumora to the
 *    front / posts a notification first), `cancel` (gives up a pending
 *    request: Dart's consent timeout), `stop`, `isRunning`, `supported`;
 *    calls back `stopped` when capture ends without Dart asking.
 *  - `lumora/input`: `isEnabled` (accessibility service), `openGuide`,
 *    `openSettings`, `inject` (forward one `remote_input` event map by hand).
 *  - `lumora/media`: `saveToGallery` (photo editor / viewer "Lưu về máy"),
 *    `saveToDownloads {path, name}` (file "Lưu": public Download/Lumora),
 *    `heicToJpeg` (camera HEIC → JPEG before sending / for display).
 *  - `lumora/camera`: video-call camera ([CameraCapture]): `supported`,
 *    `permission` / `request` (granted | denied | undetermined | blocked),
 *    `start {facing}`, `switch`, `stop`, `openSettings`; calls back `onError`.
 *    `requestMic` → granted | denied: RECORD_AUDIO before a call starts or is
 *    answered (the core opens the microphone itself through AAudio, which
 *    fails without it — the call would go out silent).
 *  - `lumora/links`: Lumora links opened from other apps (App Links on
 *    getlumora.pages.dev, `lumora://`; see AndroidManifest). `ready` returns
 *    the links that came before Dart listened; later ones arrive as `open`.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PROJECTION = 4711
        private const val REQ_NOTIF = 4712
        private const val REQ_CAMERA = 4713
        private const val REQ_MIC = 4714
        private const val PREFS = "lumora_camera"
        private const val ENGINE_ID = "lumora_main"
        const val EXTRA_ASK_PROJECTION = "vn.lumora.ASK_PROJECTION"
        /** Matches the Dart-side consent timeout (AndroidBridge.consentTimeout). */
        private const val CONSENT_TIMEOUT_MS = 60_000L

        /**
         * Screen-share consent requested by Dart and not answered yet. Static:
         * the request may outlive the Activity that received it (it was in the
         * background or destroyed) and is answered by whichever Activity shows
         * the consent dialog.
         */
        private var pendingProjection: MethodChannel.Result? = null
        private var consentShowing = false

        /** The resumed Activity, if any (main thread only). */
        private var resumed: MainActivity? = null

        /** Answers (and forgets) a pending consent request. */
        private fun finishProjectionRequest(ctx: Context, ok: Boolean) {
            val r = pendingProjection
            pendingProjection = null
            Notifier.cancelScreenConsent(ctx)
            r?.success(ok)
        }

        /** Last `setSecure` value; re-applied when a new Activity attaches to the cached engine. */
        @Volatile private var secure = false

        /** Last `setRecentsHidden` value (app lock on: blank recent-apps preview). */
        @Volatile private var recentsHidden = false

        /** Links opened before Dart called `lumora/links.ready` (main thread only). */
        private val pendingLinks = mutableListOf<String>()
        /** Dart listens on `lumora/links` (the engine, and so Dart, outlives Activities). */
        private var linksReady = false
        private const val LINK_HOST = "getlumora.pages.dev"
    }

    private fun applySecure() {
        if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /** Android 13+: no screenshot of the app in the recent-apps switcher. */
    private fun applyRecents() {
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!recentsHidden)
    }

    /**
     * One Flutter engine per process. The node runs in-process and the
     * foreground service keeps the process alive after the user leaves the
     * Activity (Back); re-using the engine keeps the Dart side (stores, event
     * pump, AndroidBridge that reacts to remote sessions) alive too, so the UI
     * re-opens instantly instead of re-booting against a running core.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var pendingCamera: MethodChannel.Result? = null
    private val pendingMic = mutableListOf<MethodChannel.Result>()

    private fun micGranted() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /**
     * Camera permission as the Dart side needs it: `undetermined` (never asked:
     * show our rationale, then the system prompt), `denied` (asked, may ask
     * again), `blocked` ("don't ask again" / policy: only Settings can fix it).
     */
    private fun cameraPermission(): String {
        if (CameraCapture.hasPermission(this)) return "granted"
        val asked = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("asked", false)
        return when {
            !asked -> "undetermined"
            shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) -> "denied"
            else -> "blocked"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not on re-creation: the same launch intent would open its link twice.
        if (savedInstanceState == null) takeLink(intent)
        applySecure()
        applyRecents()
        Lang.get(this) // warm the cache off the notification path
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LumoraNative.init(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        registerLinks(messenger)

        MethodChannel(messenger, "lumora/service").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> { LumoraService.start(applicationContext); result.success(true) }
                "stop" -> { LumoraService.stop(applicationContext); result.success(true) }
                "setLanguage" -> {
                    if (Lang.set(applicationContext, call.argument<String>("lang"))) {
                        Notifier.ensureChannels(applicationContext)
                        LumoraService.refresh()
                    }
                    result.success(true)
                }
                "setCall" -> {
                    LumoraService.setCall(call.argument<Boolean>("active") ?: false)
                    result.success(true)
                }
                "notify" -> {
                    Notifier.show(
                        applicationContext,
                        call.argument<String>("kind") ?: "message",
                        call.argument<String>("key") ?: "lumora",
                        call.argument<String>("title") ?: "Lumora",
                        call.argument<String>("body") ?: "",
                    )
                    result.success(true)
                }
                "setSecure" -> {
                    secure = call.argument<Boolean>("on") ?: false
                    runOnUiThread { applySecure() }
                    result.success(true)
                }
                "setRecentsHidden" -> {
                    recentsHidden = call.argument<Boolean>("on") ?: false
                    runOnUiThread { applyRecents() }
                    result.success(true)
                }
                "clearNotifications" -> { Notifier.cancelAll(applicationContext); result.success(true) }
                "cancelNotification" -> { Notifier.cancel(applicationContext, call.argument<String>("key") ?: ""); result.success(true) }
                "info" -> result.success(mapOf(
                    "sdk" to Build.VERSION.SDK_INT,
                    "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
                    "media" to LumoraNative.available,
                    "service" to LumoraService.running,
                ))
                else -> result.notImplemented()
            }
        }

        val screen = MethodChannel(messenger, "lumora/screen")
        ScreenCapture.onStoppedExternally = { screen.invokeMethod("stopped", null) }
        screen.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(LumoraNative.available)
                "isRunning" -> result.success(ScreenCapture.active)
                "start" -> {
                    if (!LumoraNative.available) { result.success(false); return@setMethodCallHandler }
                    if (ScreenCapture.active) { result.success(true); return@setMethodCallHandler }
                    if (pendingProjection != null) { result.success(false); return@setMethodCallHandler }
                    pendingProjection = result
                    requestProjection(applicationContext)
                }
                "cancel" -> { finishProjectionRequest(applicationContext, false); result.success(true) }
                "stop" -> {
                    finishProjectionRequest(applicationContext, false)
                    if (LumoraService.running) {
                        applicationContext.startService(Intent(applicationContext, LumoraService::class.java).setAction(LumoraService.ACTION_STOP_PROJECTION))
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "lumora/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name") ?: "Lumora.jpg"
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (bytes == null) {
                        result.error("bad_args", "bytes missing", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val saved = GallerySaver.save(applicationContext, bytes, name, mime)
                            runOnUiThread { result.success(saved) }
                        } catch (t: Throwable) {
                            runOnUiThread { result.error("save_failed", t.message, null) }
                        }
                    }.start()
                }
                "saveToDownloads" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("bad_args", "path/name missing", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val saved = GallerySaver.saveToDownloads(applicationContext, path, name)
                            runOnUiThread { result.success(saved) }
                        } catch (t: Throwable) {
                            runOnUiThread { result.error("save_failed", t.message, null) }
                        }
                    }.start()
                }
                "heicToJpeg" -> {
                    val path = call.argument<String>("path")
                    val maxSide = call.argument<Int>("maxSide") ?: 0
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val jpeg = try { GallerySaver.heicToJpeg(path, maxSide) } catch (_: Throwable) { null }
                        runOnUiThread { result.success(jpeg) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        val camera = MethodChannel(messenger, "lumora/camera")
        CameraCapture.onError = { code, message -> camera.invokeMethod("onError", mapOf("code" to code, "message" to message)) }
        camera.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(CameraCapture.supported(applicationContext))
                "permission" -> result.success(cameraPermission())
                "request" -> {
                    if (CameraCapture.hasPermission(this)) { result.success("granted"); return@setMethodCallHandler }
                    if (pendingCamera != null) { result.success(cameraPermission()); return@setMethodCallHandler }
                    pendingCamera = result
                    requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
                }
                "requestMic" -> {
                    if (micGranted()) { result.success("granted"); return@setMethodCallHandler }
                    pendingMic.add(result)
                    if (pendingMic.size == 1) requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
                }
                "start" -> CameraCapture.start(this, call.argument<String>("facing") ?: "front") { result.success(it) }
                "switch" -> CameraCapture.switch(this) { result.success(it) }
                "stop" -> { CameraCapture.stop(); result.success(null) }
                "openSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                        result.success(true)
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "lumora/input").setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(LumoraAccessibilityService.isEnabled(applicationContext))
                "openGuide" -> {
                    startActivity(Intent(this, AccessibilityGuideActivity::class.java))
                    result.success(true)
                }
                "openSettings" -> {
                    try { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) } catch (_: Throwable) {}
                    result.success(true)
                }
                "inject" -> {
                    val ev = call.arguments as? Map<*, *>
                    if (ev != null) LumoraAccessibilityService.dispatch(this, JSONObject(ev))
                    result.success(ev != null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Asks for screen-capture consent. The system dialog only shows over a
     * visible Activity: asking from the background used to hang forever. If
     * Lumora is not in front, bring it there (allowed while our accessibility
     * service is on; otherwise Android blocks it silently) and post a
     * notification whose tap opens Lumora; [onResume] then shows the dialog.
     */
    private fun requestProjection(app: Context) {
        val act = resumed
        if (act != null && !act.isFinishing && !act.isDestroyed) {
            act.launchConsent()
            return
        }
        try {
            app.startActivity(Notifier.openAppIntent(app).putExtra(EXTRA_ASK_PROJECTION, true))
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "cannot bring Lumora to the front: $t")
        }
        Notifier.showScreenConsent(app, CONSENT_TIMEOUT_MS)
    }

    private fun launchConsent() {
        if (pendingProjection == null || consentShowing) return
        Notifier.cancelScreenConsent(applicationContext)
        try {
            val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            @Suppress("DEPRECATION")
            startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION)
            consentShowing = true
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "consent dialog failed: $t")
            finishProjectionRequest(applicationContext, false)
        }
    }

    private var linksChannel: MethodChannel? = null

    private fun registerLinks(messenger: io.flutter.plugin.common.BinaryMessenger) {
        linksChannel = MethodChannel(messenger, "lumora/links").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    linksReady = true
                    val queued = ArrayList(pendingLinks)
                    pendingLinks.clear()
                    result.success(queued)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeLink(intent)
    }

    /** A Lumora link from a VIEW intent → Dart (Dart validates it again). */
    private fun takeLink(i: Intent?) {
        if (i == null || i.action != Intent.ACTION_VIEW) return
        if ((i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        val link = i.dataString?.trim() ?: return
        val uri = i.data ?: return
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        val ok = link.length <= 4200 && when (scheme) {
            "lumora" -> host == "add" || host == "join" || host == "remote"
            "https" -> host == LINK_HOST
            else -> false
        }
        if (!ok) return
        val ch = linksChannel
        if (linksReady && ch != null) ch.invokeMethod("open", link) else pendingLinks.add(link)
    }

    override fun onResume() {
        super.onResume()
        resumed = this
        // A screen-share request waiting for Lumora to be in front.
        launchConsent()
        // The service could not start from the background, or stopped after
        // an Android 15 FGS timeout: start it again now that we are in front.
        if (LumoraService.wanted && !LumoraService.running) LumoraService.start(applicationContext)
    }

    override fun onPause() {
        if (resumed === this) resumed = null
        super.onPause()
    }

    override fun onDestroy() {
        if (resumed === this) resumed = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean("asked", true).apply()
            val r = pendingCamera
            pendingCamera = null
            r?.success(cameraPermission())
        }
        if (requestCode == REQ_MIC) {
            val answer = if (micGranted()) "granted" else "denied"
            val waiting = pendingMic.toList()
            pendingMic.clear()
            waiting.forEach { it.success(answer) }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PROJECTION) {
            consentShowing = false
            val r = pendingProjection
            pendingProjection = null
            Notifier.cancelScreenConsent(applicationContext)
            // r == null: Dart gave up meanwhile (timeout / session ended) — the
            // consent is not used.
            if (r != null && resultCode == RESULT_OK && data != null) {
                val i = Intent(this, LumoraService::class.java)
                    .setAction(LumoraService.ACTION_PROJECTION)
                    .putExtra(LumoraService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(LumoraService.EXTRA_RESULT_DATA, data)
                try {
                    startForegroundService(i)
                    r.success(true)
                } catch (t: Throwable) {
                    android.util.Log.w("MainActivity", "screen-share service: $t")
                    r.success(false)
                }
            } else {
                r?.success(false)
            }
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
