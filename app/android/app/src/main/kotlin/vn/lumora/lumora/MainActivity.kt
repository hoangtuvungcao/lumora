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
open class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PROJECTION = 4711
        private const val REQ_NOTIF = 4712
        private const val REQ_CAMERA = 4713
        private const val REQ_MIC = 4714
        private const val PREFS = "lumora_camera"
        const val ENGINE_ID = LumoraEngine.ENGINE_ID
        const val EXTRA_ASK_PROJECTION = "vn.lumora.ASK_PROJECTION"
        /** Opened from the incoming-call notification (full-screen intent). */
        const val EXTRA_INCOMING_CALL = "vn.lumora.INCOMING_CALL"
        /** "Mở" on a reminder notification: the reminder (JSON) whose chat to open. */
        const val EXTRA_REMINDER_OPEN = "vn.lumora.REMINDER_OPEN"
        /** "answer": Answer on the incoming-call notification (Dart answers once Lumora is in front). */
        const val EXTRA_CALL_ACTION = "vn.lumora.CALL_ACTION"

        /** A video call is live (Dart): leaving the app goes picture-in-picture. */
        @Volatile private var pipWanted = false

        fun setPipWanted(on: Boolean) {
            pipWanted = on
            current()?.let { a -> a.runOnUiThread { a.applyPipParams() } }
        }

        /** The Activity shown over the lock screen for a ringing call. */
        private var overLock: MainActivity? = null
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

        /** The Activity attached to the engine (MainActivity or a bubble), if any. Main thread. */
        private var attached: MainActivity? = null

        /** Chat bubbles between onResume and onPause (expanded). Main thread. */
        private val resumedBubbles = mutableSetOf<MainActivity>()

        /** The main window while it is visible (onStart..onStop). Main thread. */
        private var startedMain: MainActivity? = null

        /** Dart has drawn a frame in some window of this process (it is past its cold start). */
        @Volatile internal var uiEverShown = false

        /** Lumora's main window has input focus (the user is in it, not in a bubble). */
        internal fun mainHasFocus(): Boolean = startedMain?.hasWindowFocus() == true

        /** Dart listens on `lumora/links` now: the links that came before it. Main thread. */
        fun takeQueuedLinks(): ArrayList<String> {
            linksReady = true
            val queued = ArrayList(pendingLinks)
            pendingLinks.clear()
            return queued
        }

        fun current(): MainActivity? = attached?.takeIf { !it.isFinishing && !it.isDestroyed }

        fun setSecure(on: Boolean) {
            secure = on
            current()?.let { a -> a.runOnUiThread { a.applySecure() } }
        }

        fun setRecentsHidden(on: Boolean) {
            recentsHidden = on
            current()?.let { a -> a.runOnUiThread { a.applyRecents() } }
        }

        /** Links opened before Dart called `lumora/links.ready` (main thread only). */
        private val pendingLinks = mutableListOf<String>()
        /** Dart listens on `lumora/links` (the engine, and so Dart, outlives Activities). */
        private var linksReady = false
        private const val LINK_HOST = "getlumora.pages.dev"
    }

    internal fun applySecure() {
        if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /** Android 13+: no screenshot of the app in the recent-apps switcher. */
    internal fun applyRecents() {
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!recentsHidden)
    }

    /**
     * One Flutter engine per process. The node runs in-process and the
     * foreground service keeps the process alive after the user leaves the
     * Activity (Back); re-using the engine keeps the Dart side (stores, event
     * pump, AndroidBridge that reacts to remote sessions) alive too, so the UI
     * re-opens instantly instead of re-booting against a running core.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = LumoraEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    // ------------------------------------------------- engine hand-over
    //
    // One engine, one FlutterView at a time: the main window and chat bubbles
    // ([BubbleActivity]) take it from each other. FlutterActivity attaches in
    // onCreate and evicts whoever had it (its view goes blank and its later
    // lifecycle calls are ignored by Flutter); an evicted window gets it back
    // with [recreate].
    //
    // Who gets it does NOT depend on onTopResumedActivityChanged alone: OEM
    // bubble / floating-window implementations (Xiaomi HyperOS) don't always
    // make the expanded bubble the top-resumed activity, or keep it visible but
    // paused. The rule:
    //  - a bubble takes the engine whenever it is shown (onStart/onResume),
    //    gets focus or becomes top-resumed;
    //  - the main window takes it back when it gets focus or becomes
    //    top-resumed while no bubble is in front, and when the bubble that had
    //    it goes away (onStop) while the main window is visible.

    /**
     * Another Activity (a chat bubble, or Lumora itself after a bubble) took
     * the engine: this one shows nothing until it attaches again ([claimEngine]).
     */
    private var evicted = false

    /** A chat bubble's window (false: Lumora's main window). */
    protected open val isBubbleWindow: Boolean get() = false

    override fun detachFromFlutterEngine() {
        evicted = true
        if (attached === this) attached = null
        super.detachFromFlutterEngine()
    }

    /** Takes the engine back if another window took it (re-creating this one attaches it). */
    protected fun claimEngine(why: String) {
        if (!evicted || isFinishing || isDestroyed || isChangingConfigurations) return
        android.util.Log.i("MainActivity", "${javaClass.simpleName}: taking the Flutter view back ($why)")
        evicted = false
        recreate()
    }

    /** The main window may take the engine back: no chat bubble is in front of it. */
    private fun mainMayClaim() = resumedBubbles.none { !it.isFinishing }

    /** This window has lost the engine to another one. */
    protected val isEvicted: Boolean get() = evicted

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        uiEverShown = true
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        if (!isTopResumedActivity || !evicted) return
        if (isBubbleWindow) claimEngine("top resumed")
        // after the other window's onPause (same frame) — a collapsing bubble pauses after this
        else window.decorView.post { if (mainMayClaim()) claimEngine("top resumed") }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || !evicted) return
        if (isBubbleWindow) claimEngine("focus")
        // the user is in the main window: a bubble keeps the engine only while it has focus itself
        else window.decorView.post { if (hasWindowFocus() && resumedBubbles.none { it.hasWindowFocus() }) claimEngine("focus") }
    }

    override fun onStart() {
        super.onStart()
        if (!isBubbleWindow) startedMain = this
        if (isBubbleWindow && evicted) {
            claimEngine("shown")
        } else if (attached === this) {
            // Visible: let Dart draw even if this window is never resumed (OEM
            // multi-window / floating windows keep visible windows paused).
            // Flutter itself only says "resumed" in onResume; until then Dart may
            // still be "paused"/"detached" (frames off) from the window that had
            // the engine, and nothing would ever be drawn here.
            flutterEngine?.lifecycleChannel?.appIsInactive()
        }
    }

    override fun onStop() {
        super.onStop()
        if (startedMain === this) startedMain = null
        // A bubble collapsed / closed: give the engine back to the main window if it is on screen.
        if (isBubbleWindow && attached === this && !isChangingConfigurations) {
            startedMain?.let { m -> m.window.decorView.post { if (m.mainMayClaim()) m.claimEngine("bubble hidden") } }
        }
    }

    /** Answer pressed on the incoming-call notification (once). */
    private fun takeCallAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_CALL_ACTION) ?: return
        intent.removeExtra(EXTRA_CALL_ACTION)
        Notifier.cancel(applicationContext, "call")
        LumoraEngine.callAction(action, intent.getStringExtra(CallActions.EXTRA_CALL_ID) ?: "")
    }

    /** A chat to open from a notification, bubble or launcher shortcut (once). */
    private fun takeOpenConv(intent: Intent?) {
        val conv = LumoraEngine.convOf(intent) ?: return
        intent?.removeExtra(Notifier.EXTRA_CONV)
        LumoraEngine.openConv(conv)
    }

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

    private fun pipParams(): android.app.PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < 26) return null
        val b = android.app.PictureInPictureParams.Builder().setAspectRatio(android.util.Rational(9, 16))
        // Android 12+: the system enters picture-in-picture by itself on Home / gesture
        if (Build.VERSION.SDK_INT >= 31) b.setAutoEnterEnabled(pipWanted).setSeamlessResizeEnabled(true)
        return b.build()
    }

    /** Bubbles share this class: only the main window goes picture-in-picture. */
    private val pipCapable get() = javaClass == MainActivity::class.java

    fun applyPipParams() {
        if (Build.VERSION.SDK_INT < 26 || !pipCapable) return
        try {
            pipParams()?.let { setPictureInPictureParams(it) }
        } catch (_: Throwable) {
            // PiP disabled for Lumora by the user / device: nothing to do
        }
    }

    /** Tells Dart (AndroidBridge.pip) when the main window enters / leaves picture-in-picture. */
    private fun sendPip(on: Boolean) {
        LumoraEngine.channel()?.invokeMethod("pip", mapOf("on" to on))
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (pipCapable) sendPip(isInPictureInPictureMode)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 8–11 (12+ enters by itself via setAutoEnterEnabled)
        if (pipWanted && pipCapable && Build.VERSION.SDK_INT in 26..30 && !isInPictureInPictureMode) {
            try {
                pipParams()?.let { enterPictureInPictureMode(it) }
            } catch (_: Throwable) {
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not on re-creation: the same launch intent would open its link twice.
        if (savedInstanceState == null) {
            takeLink(intent)
            takeOpenConv(intent)
            takeCallAction(intent)
        }
        showOverLockIfRinging(intent)
        takeReminderOpen(intent)
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
        evicted = false
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        registerLinks(messenger)

        // `lumora/service` lives with the engine (LumoraEngine): it works without an Activity.
        attached = this

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
                    result.success(takeQueuedLinks())
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
        showOverLockIfRinging(intent)
        takeReminderOpen(intent)
        takeOpenConv(intent)
        takeCallAction(intent)
    }

    /** "Mở" on a reminder notification: Dart opens its chat (once). */
    private fun takeReminderOpen(intent: Intent?) {
        val data = intent?.getStringExtra(EXTRA_REMINDER_OPEN) ?: return
        intent.removeExtra(EXTRA_REMINDER_OPEN)
        intent.getStringExtra(ReminderActions.EXTRA_KEY)?.let { Notifier.cancel(applicationContext, it) }
        ReminderActions.toDart("open", data) {}
    }

    /**
     * Opened by the incoming-call notification's full-screen intent while the
     * phone is locked: show the call screen over the lock screen and turn the
     * screen on — only while the call rings ([CallTones.onRingingChanged]
     * hides it again; answering then asks to unlock as usual).
     */
    private fun showOverLockIfRinging(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_INCOMING_CALL, false) != true || !CallTones.ringing) return
        setOverLock(true)
        overLock = this
        CallTones.onRingingChanged = { on ->
            if (!on) {
                overLock?.setOverLock(false)
                overLock = null
            }
        }
    }

    private fun setOverLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
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
        if (isBubbleWindow) resumedBubbles.add(this)
        else if (evicted) window.decorView.post { if (mainMayClaim()) claimEngine("resumed") }
        // A screen-share request waiting for Lumora to be in front.
        launchConsent()
        // The service could not start from the background, or stopped after
        // an Android 15 FGS timeout: start it again now that we are in front.
        if (LumoraService.wanted && !LumoraService.running) LumoraService.start(applicationContext)
    }

    override fun onPause() {
        if (resumed === this) resumed = null
        resumedBubbles.remove(this)
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (attached === this) attached = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // closed while in picture-in-picture (its window swiped away): Dart must not stay in PiP mode
        if (pipCapable && isInPictureInPictureMode) sendPip(false)
        if (resumed === this) resumed = null
        resumedBubbles.remove(this)
        if (startedMain === this) startedMain = null
        if (attached === this) attached = null
        if (overLock === this) overLock = null
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
