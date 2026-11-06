package vn.lumora.lumora

import android.util.Log
import java.nio.ByteBuffer

/**
 * JNI entry points of liblumora_ffi.so used by the Android shell (the Dart
 * side opens the same library through dart:ffi for everything else).
 *
 * They exist only when the core was built with the `media` feature; when they
 * are missing [available] is false and screen sharing / remote control are
 * reported as unsupported instead of crashing.
 */
object LumoraNative {
    private const val TAG = "LumoraNative"

    val available: Boolean by lazy {
        try {
            System.loadLibrary("lumora_ffi")
            // Probe one symbol: throws UnsatisfiedLinkError if the core lacks media support.
            clearFrames()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "native media entry points unavailable: $t")
            false
        }
    }

    /** Give the audio backend the JVM + app context (call once, before calls start). */
    @JvmStatic external fun initContext(ctx: android.content.Context)

    /** Safe wrapper: no-op when the core lacks media support. */
    fun init(ctx: android.content.Context) {
        if (!available) return
        try { initContext(ctx.applicationContext) } catch (t: Throwable) { Log.w(TAG, "initContext failed: $t") }
    }

    /** Push one RGBA_8888 frame (direct buffer). 0 ok, <0 error. */
    @JvmStatic external fun pushFrame(width: Int, height: Int, stride: Int, plane: ByteBuffer): Int

    /**
     * Push one camera picture (CameraX YUV_420_888 planes as direct buffers) into
     * the call. `rotation`: clockwise degrees to upright, OR 0x10000 for full range.
     * 0 accepted, 1 encoder busy, 2 no call wants the camera, -1 bad input.
     */
    @JvmStatic external fun pushCameraYuv(
        width: Int, height: Int,
        y: ByteBuffer, yStride: Int,
        u: ByteBuffer, uStride: Int,
        v: ByteBuffer, vStride: Int,
        uvPixelStride: Int, rotation: Int,
    ): Int

    /** Describe the captured screen (size of the frames that will be pushed). */
    @JvmStatic external fun setDisplay(width: Int, height: Int, scale: Float)

    /** Drop queued frames (projection stopped). */
    @JvmStatic external fun clearFrames()

    /** Blocks ≤ timeoutMs; writes one JSON input event into [buf], returns its length (0 = none). */
    @JvmStatic external fun nextInput(buf: ByteBuffer, timeoutMs: Int): Int
}
