package vn.lumora.lumora

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager

/**
 * MediaProjection → VirtualDisplay → ImageReader(RGBA_8888) → Rust
 * (`LumoraNative.pushFrame`, i.e. lumora_media::push_external_frame).
 *
 * Frames are downscaled so the long side is ≤ [MAX_SIDE] px (software H.264
 * on a phone CPU) and rate-limited to [MAX_FPS].
 */
class ScreenCapture(
    private val ctx: Context,
    private val resultCode: Int,
    private val data: Intent,
    private val onStopped: () -> Unit,
) {
    companion object {
        private const val TAG = "ScreenCapture"
        const val MAX_SIDE = 1280
        const val MAX_FPS = 30
        @Volatile var active = false

        /**
         * Set by [MainActivity]: tells Dart (`lumora/screen` → `stopped`) that
         * capture ended without Dart asking — the user stopped sharing from the
         * status bar, the screen locked, consent could not be used… Dart then
         * ends the remote host session(s) instead of streaming a frozen frame.
         */
        @Volatile var onStoppedExternally: (() -> Unit)? = null

        private val main = Handler(Looper.getMainLooper())

        fun reportStopped() {
            main.post { onStoppedExternally?.invoke() }
        }

        /** Size of the frames we push: real size scaled so the long side is ≤ MAX_SIDE. */
        fun captureSize(ctx: Context): Triple<Int, Int, Float> {
            val (rw, rh) = realSize(ctx)
            val scale = minOf(1f, MAX_SIDE.toFloat() / maxOf(rw, rh))
            return Triple(((rw * scale).toInt() / 2) * 2, ((rh * scale).toInt() / 2) * 2, scale)
        }

        /** Real (physical) screen size in pixels. */
        fun realSize(ctx: Context): Pair<Int, Int> {
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            return if (android.os.Build.VERSION.SDK_INT >= 30) {
                val b = wm.maximumWindowMetrics.bounds
                b.width() to b.height()
            } else {
                val m = DisplayMetrics()
                @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
                m.widthPixels to m.heightPixels
            }
        }
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var lastPush = 0L
    /** stop() was called by us: the projection's onStop is expected, not news. */
    @Volatile private var stopping = false

    fun start() {
        val mpm = ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mpm.getMediaProjection(resultCode, data) ?: throw IllegalStateException("no projection")
        projection = p
        val (rw, rh) = realSize(ctx)
        val (w, h, scale) = captureSize(ctx)
        val dpi = (ctx.resources.displayMetrics.densityDpi * scale).toInt().coerceAtLeast(120)
        LumoraNative.setDisplay(w, h, ctx.resources.displayMetrics.density * scale)

        val t = HandlerThread("lumora-capture").also { it.start() }
        thread = t
        val handler = Handler(t.looper)
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        reader = r
        r.setOnImageAvailableListener({ ir ->
            val img = try { ir.acquireLatestImage() } catch (e: Throwable) { null } ?: return@setOnImageAvailableListener
            try {
                val now = SystemClock.elapsedRealtime()
                if (now - lastPush >= 1000L / MAX_FPS) {
                    lastPush = now
                    val plane = img.planes[0]
                    LumoraNative.pushFrame(img.width, img.height, plane.rowStride, plane.buffer)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "push failed: $e")
            } finally {
                img.close()
            }
        }, handler)

        // Android 14+: a callback must be registered before createVirtualDisplay.
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                if (stopping) return
                Log.i(TAG, "projection stopped by the system/user")
                main.post { if (!stopping) onStopped() }
            }
        }, handler)
        display = p.createVirtualDisplay(
            "lumora-screen", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            r.surface, null, handler,
        )
        Log.i(TAG, "capturing ${rw}x$rh as ${w}x$h")
    }

    fun stop() {
        stopping = true
        try { reader?.setOnImageAvailableListener(null, null) } catch (_: Throwable) {}
        try { display?.release() } catch (_: Throwable) {}
        try { reader?.close() } catch (_: Throwable) {}
        try { projection?.stop() } catch (_: Throwable) {}
        thread?.quitSafely()
        display = null; reader = null; projection = null; thread = null
        try { if (LumoraNative.available) LumoraNative.clearFrames() } catch (_: Throwable) {}
    }
}
