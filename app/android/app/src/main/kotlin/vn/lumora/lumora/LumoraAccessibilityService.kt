package vn.lumora.lumora

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Injects remote-control input on Android (the only non-root way to do so).
 *
 * The core queues viewer input as JSON (see lumora-media/src/input/android.rs);
 * [LumoraService]'s pump thread hands each event to [dispatch], which turns the
 * mouse model of the desktop viewer into touch gestures:
 *
 *  - left button down → move → up: tap (short, still), long-press (≥ 500 ms,
 *    still) or a swipe/drag along the recorded path;
 *  - wheel: a short fling at the pointer position;
 *  - right button / Escape / BrowserBack / back button → BACK;
 *    middle button / Meta / BrowserHome → HOME; ContextMenu → RECENTS;
 *    custom codes `AndroidBack`, `AndroidHome`, `AndroidRecents`,
 *    `AndroidNotifications`, `AndroidQuickSettings`, `AndroidLock`;
 *  - text → inserted at the caret of the focused field, replacing the
 *    selection (ACTION_SET_TEXT + ACTION_SET_SELECTION). Password fields (and
 *    fields whose text is not readable) only expose masked text, so there the
 *    text goes in through the clipboard (ACTION_PASTE) — see [paste];
 *    Backspace / Delete remove the selection or one character before / after
 *    the caret; Enter → IME action.
 *
 * Coordinates are normalised 0..1 over the whole (mirrored) screen.
 */
class LumoraAccessibilityService : AccessibilityService() {
    companion object {
        private const val TAG = "LumoraA11y"
        @Volatile var instance: LumoraAccessibilityService? = null
            private set

        fun isEnabled(ctx: Context): Boolean {
            if (instance != null) return true
            val want = ComponentName(ctx, LumoraAccessibilityService::class.java)
            val list = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val split = TextUtils.SimpleStringSplitter(':').apply { setString(list) }
            for (s in split) {
                val cn = ComponentName.unflattenFromString(s)
                if (cn != null && cn == want) return true
            }
            return false
        }

        private var warned = false

        /** Called from the input pump thread (or a method channel) with one event. */
        fun dispatch(ctx: Context, ev: JSONObject) {
            val svc = instance
            if (svc == null) {
                if (!warned) {
                    warned = true
                    Log.w(TAG, "remote input received but the accessibility service is off")
                }
                return
            }
            svc.main.post { svc.handle(ev) }
        }
    }

    private val main = Handler(Looper.getMainLooper())

    // pointer state (screen pixels)
    private var px = 0f
    private var py = 0f
    private var down = false
    private var downAt = 0L
    private val path = ArrayList<FloatArray>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "accessibility service connected")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    private fun screen(): Pair<Int, Int> = ScreenCapture.realSize(this)

    fun handle(ev: JSONObject) {
        try {
            when (ev.optString("t")) {
                "move" -> {
                    val (w, h) = screen()
                    px = (ev.optDouble("x", 0.0).coerceIn(0.0, 1.0) * (w - 1)).toFloat()
                    py = (ev.optDouble("y", 0.0).coerceIn(0.0, 1.0) * (h - 1)).toFloat()
                    if (down) {
                        val last = path.last()
                        if (hypot(px - last[0], py - last[1]) >= 4f) path.add(floatArrayOf(px, py))
                    }
                }
                "button" -> button(ev.optString("b"), ev.optBoolean("down"))
                "wheel" -> wheel(ev.optInt("dx"), ev.optInt("dy"))
                "key" -> if (ev.optBoolean("down")) key(ev.optString("code"))
                "text" -> typeText(ev.optString("s"))
                "tap" -> { // direct tap from a touch viewer: {"t":"tap","x":..,"y":..}
                    val (w, h) = screen()
                    tap(ev.optDouble("x").toFloat() * w, ev.optDouble("y").toFloat() * h, 60)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "input failed: $t")
        }
    }

    private fun button(b: String, isDown: Boolean) {
        when (b) {
            "left" -> if (isDown) {
                down = true
                downAt = SystemClock.uptimeMillis()
                path.clear()
                path.add(floatArrayOf(px, py))
            } else if (down) {
                down = false
                val dur = SystemClock.uptimeMillis() - downAt
                val first = path.first()
                val moved = path.maxOf { hypot(it[0] - first[0], it[1] - first[1]) }
                when {
                    moved < 16f && dur < 500 -> tap(first[0], first[1], 50)
                    moved < 16f -> tap(first[0], first[1], dur.coerceAtMost(3000))
                    else -> stroke(path, dur.coerceIn(100, 3000))
                }
                path.clear()
            }
            "right", "back" -> if (isDown) performGlobalAction(GLOBAL_ACTION_BACK)
            "middle" -> if (isDown) performGlobalAction(GLOBAL_ACTION_HOME)
            "forward" -> if (isDown) performGlobalAction(GLOBAL_ACTION_RECENTS)
        }
    }

    private fun wheel(dx: Int, dy: Int) {
        val (w, h) = screen()
        // positive dy = scroll content down = finger moves up
        val ex = (px - dx * w * 0.18f).coerceIn(1f, w - 2f)
        val ey = (py - dy * h * 0.12f).coerceIn(1f, h - 2f)
        if (abs(ex - px) < 2 && abs(ey - py) < 2) return
        stroke(listOf(floatArrayOf(px, py), floatArrayOf(ex, ey)), 180)
    }

    private fun key(code: String) {
        when (code) {
            "Escape", "BrowserBack", "AndroidBack" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "MetaLeft", "MetaRight", "BrowserHome", "AndroidHome" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "ContextMenu", "AndroidRecents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "AndroidNotifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            "AndroidQuickSettings" -> performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
            "AndroidLock" -> if (Build.VERSION.SDK_INT >= 28) performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
            "Backspace" -> deleteText(forward = false)
            "Delete" -> deleteText(forward = true)
            "Enter", "NumpadEnter" -> {
                val n = focused() ?: return
                if (Build.VERSION.SDK_INT >= 30) {
                    n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                } else {
                    typeText("\n")
                }
            }
        }
    }

    private fun focused(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    /**
     * The focused editable field. [text] is null when its content can't be
     * read back faithfully (password fields expose masked or no text), and
     * [start]..[end] is the selection clamped to the text (both -1 if unknown).
     */
    private class Field(val node: AccessibilityNodeInfo, val text: String?, val start: Int, val end: Int)

    private fun field(): Field? {
        val n = focused() ?: return null
        if (!n.isEditable) return null
        val hint = n.isShowingHintText
        val raw = if (hint) "" else n.text?.toString()
        var a = n.textSelectionStart
        var b = n.textSelectionEnd
        if (a > b) a = b.also { b = a }
        val text = when {
            n.isPassword -> null
            raw == null -> if (b <= 0) "" else null // nothing exposed but a caret past 0: unknown content
            b > raw.length -> null // the exposed text is not the real one
            else -> raw
        }
        if (text != null && (a < 0 || b < 0)) {
            // No selection reported: type at the end (the old behaviour).
            a = text.length
            b = text.length
        }
        return Field(n, text, a, b)
    }

    private fun setText(n: AccessibilityNodeInfo, text: String, caret: Int): Boolean {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        if (!n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return false
        n.refresh()
        // A length filter may have cut the text: keep the caret inside it.
        val len = if (n.isShowingHintText) 0 else (n.text?.length ?: text.length)
        select(n, caret.coerceIn(0, len), caret.coerceIn(0, len))
        return true
    }

    private fun select(n: AccessibilityNodeInfo, start: Int, end: Int): Boolean {
        val sel = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        return n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
    }

    /** Inserts [s] at the caret, replacing the selection. */
    private fun typeText(s: String) {
        if (s.isEmpty()) return
        val f = field() ?: return
        val cur = f.text
        if (cur == null) {
            paste(f.node, s)
            return
        }
        val next = cur.substring(0, f.start) + s + cur.substring(f.end)
        if (!setText(f.node, next, f.start + s.length)) paste(f.node, s)
    }

    /** Backspace / Delete: the selection, else one character (grapheme) before / after the caret. */
    private fun deleteText(forward: Boolean) {
        val f = field() ?: return
        val cur = f.text
        if (cur == null) {
            // Masked field: select what must go, then paste nothing over it.
            if (f.start < 0 || f.end < 0) return
            if (f.start == f.end) {
                val ok = if (forward) select(f.node, f.start, f.start + 1)
                else f.start > 0 && select(f.node, f.start - 1, f.start)
                if (!ok) return
            }
            paste(f.node, "")
            return
        }
        var a = f.start
        var b = f.end
        if (a == b) {
            val it = android.icu.text.BreakIterator.getCharacterInstance()
            it.setText(cur)
            if (forward) {
                if (b >= cur.length) return
                b = it.following(b).let { e -> if (e == android.icu.text.BreakIterator.DONE) cur.length else e }
            } else {
                if (a <= 0) return
                a = it.preceding(a).let { p -> if (p == android.icu.text.BreakIterator.DONE) 0 else p }
            }
        }
        setText(f.node, cur.removeRange(a, b), a)
    }

    // ------------------------------------------------------------ clipboard paste

    /** The user's clipboard before our first paste (null: none, or not readable from here). */
    private var savedClip: ClipData? = null
    private var pasting = false
    private var pasteGen = 0

    /**
     * Types [s] through the clipboard: the only way into a password field
     * without reading (and rewriting) its masked content. The temporary clip
     * is marked sensitive (Android 13+ hides it in the clipboard preview) and
     * the previous clip is put back ~300 ms after the last paste; if Android
     * would not let us read the previous clip, the clipboard is cleared rather
     * than leaving the typed text (often a password) in it.
     */
    private fun paste(n: AccessibilityNodeInfo, s: String) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        if (!pasting) {
            savedClip = try { cm.primaryClip } catch (_: Throwable) { null }
            pasting = true
        }
        val clip = ClipData.newPlainText("", s)
        clip.description.extras = PersistableBundle().apply {
            // ClipDescription.EXTRA_IS_SENSITIVE (API 33); harmless before.
            putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        try {
            cm.setPrimaryClip(clip)
            n.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        } catch (t: Throwable) {
            Log.w(TAG, "paste failed: $t")
        }
        val gen = ++pasteGen
        main.postDelayed({
            if (gen != pasteGen) return@postDelayed // more typing came: restore after the last one
            val prev = savedClip
            savedClip = null
            pasting = false
            try {
                if (prev != null) cm.setPrimaryClip(prev)
                else if (Build.VERSION.SDK_INT >= 28) cm.clearPrimaryClip()
            } catch (t: Throwable) {
                Log.w(TAG, "clipboard restore failed: $t")
            }
        }, 300)
    }

    private fun tap(x: Float, y: Float, durMs: Long) {
        val p = Path().apply { moveTo(x, y) }
        gesture(p, durMs.coerceAtLeast(1))
    }

    private fun stroke(points: List<FloatArray>, durMs: Long) {
        val p = Path()
        p.moveTo(points[0][0], points[0][1])
        for (i in 1 until points.size) p.lineTo(points[i][0], points[i][1])
        gesture(p, durMs)
    }

    private fun gesture(p: Path, durMs: Long) {
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(p, 0, durMs.coerceIn(1, 59_000)))
            .build()
        dispatchGesture(g, null, null)
    }
}
