package vn.lumora.lumora

/**
 * A chat opened as an Android conversation bubble (Notifier: BubbleMetadata).
 * It is Lumora's own UI (same engine, same Dart app, everything in
 * [MainActivity]) attached in the bubble's window and opened on that chat;
 * the narrow window gives the phone layout. Only one Activity can show the
 * engine at a time: the other one re-attaches when it comes back in front
 * ([MainActivity.onTopResumedActivityChanged]).
 *
 * Every time the bubble is expanded it shows its own chat again (the shared
 * Dart UI may have moved elsewhere in the main window meanwhile).
 *
 * Manifest: resizeable, embeddable, `documentLaunchMode="always"` — what
 * Android requires of a bubble's Activity.
 */
class BubbleActivity : MainActivity() {
    /** The bubble's chat, from its intent data (`lumora-conv:<conv>`, never consumed). */
    private val bubbleConv: String?
        get() = intent?.data?.takeIf { it.scheme == "lumora-conv" }?.schemeSpecificPart?.takeIf { it.isNotEmpty() }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        if (isTopResumedActivity && !isFinishing) bubbleConv?.let { LumoraEngine.openConv(it) }
    }
}
