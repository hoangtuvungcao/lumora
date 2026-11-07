package vn.lumora.lumora

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.RenderMode

/**
 * A chat opened as an Android conversation bubble (Notifier: BubbleMetadata).
 * It is Lumora's own UI (same engine, same Dart app, everything in
 * [MainActivity]) attached in the bubble's window and opened on that chat;
 * the narrow window gives the phone layout. Only one Activity can show the
 * engine at a time: see "engine hand-over" in [MainActivity] — the bubble
 * takes it whenever it is shown, the main window gets it back afterwards.
 *
 * Every time the bubble is expanded it shows its own chat again (the shared
 * Dart UI may have moved elsewhere in the main window meanwhile).
 *
 * Rendering: a TextureView (Flutter draws into the bubble window's own
 * surface), not the default SurfaceView. A SurfaceView is a separate surface
 * that the OEM's bubble / floating-window container must place and show, and
 * Flutter holds back the window's very first draw until that surface showed a
 * frame — when either fails (seen on Xiaomi HyperOS) the bubble stays an
 * empty grey container. With a texture the window draws at once (the app's
 * background), and Flutter's frames are ordinary window content.
 *
 * Manifest: resizeable, embeddable, `documentLaunchMode="always"` — what
 * Android requires of a bubble's Activity.
 */
class BubbleActivity : MainActivity() {
    override val isBubbleWindow: Boolean get() = true

    override fun getRenderMode(): RenderMode = RenderMode.texture

    /** The bubble's chat, from its intent data (`lumora-conv:<conv>`, never consumed). */
    private val bubbleConv: String?
        get() = intent?.data?.takeIf { it.scheme == "lumora-conv" }?.schemeSpecificPart?.takeIf { it.isNotEmpty() }

    /** Show the bubble's chat again on the next onResume (created / expanded again). */
    private var reopen = true

    private val main = Handler(Looper.getMainLooper())

    /** Flutter has drawn into this bubble since it attached. */
    private var uiShown = false

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        uiShown = true
    }

    override fun onFlutterUiNoLongerDisplayed() {
        super.onFlutterUiNoLongerDisplayed()
        uiShown = false
    }

    override fun onResume() {
        super.onResume()
        if (reopen && !isEvicted) {
            reopen = false
            bubbleConv?.let { LumoraEngine.openConv(it) }
        }
        main.removeCallbacks(checkShown)
        main.postDelayed(checkShown, SHOW_TIMEOUT_MS)
    }

    override fun onPause() {
        main.removeCallbacks(checkShown)
        super.onPause()
    }

    override fun onStop() {
        super.onStop()
        reopen = true
        if (!isChangingConfigurations) healTries = 0 // not when re-created by the self-heal
    }

    override fun onDestroy() {
        main.removeCallbacks(checkShown)
        super.onDestroy()
    }

    /**
     * Safety net: expanded for a while and still nothing of Lumora drawn (the
     * engine went to the main window without the bubble being told, or never
     * produced a frame here although Dart is running) — and the user is not
     * busy in Lumora's main window: attach again (at most [MAX_HEAL_TRIES]
     * times per expansion).
     */
    private val checkShown = Runnable {
        if (isFinishing || isDestroyed || uiShown && !isEvicted || healTries >= MAX_HEAL_TRIES || mainHasFocus()) return@Runnable
        // cold start (Lumora was not running): Dart is still booting, attaching again won't help
        if (!isEvicted && !uiEverShown) return@Runnable
        healTries++
        android.util.Log.w("BubbleActivity", "bubble not drawn after ${SHOW_TIMEOUT_MS} ms (evicted=$isEvicted): attaching again")
        if (isEvicted) claimEngine("not drawn") else recreate()
    }

    private companion object {
        const val SHOW_TIMEOUT_MS = 1500L
        const val MAX_HEAL_TRIES = 2

        /** Self-heal attempts since the bubble was last hidden (re-created instances share it). */
        var healTries = 0
    }
}
