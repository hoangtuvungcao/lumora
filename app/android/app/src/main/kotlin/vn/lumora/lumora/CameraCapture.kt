package vn.lumora.lumora

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Video-call camera: CameraX `ImageAnalysis` (YUV_420_888, ~1280x720, 30 fps)
 * → `LumoraNative.pushCameraYuv` with the planes' direct ByteBuffers → Rust
 * (`lumora_media::camera_in`), which rotates upright, converts to I420 and
 * feeds the encoder + beauty filter in one pass. Nothing goes through Dart;
 * the self-view is the core's processed `video_stream {local: true}`.
 *
 * Why not the `camera` Flutter plugin: its image stream copies every plane
 * into a byte[] → platform channel → Dart → native memory, ~4 copies of
 * 1.4 MB at 30 fps, plus a preview texture we don't need.
 *
 * Rotation: an OrientationEventListener keeps `targetRotation` on the physical
 * device orientation (the UI may be locked to portrait), so
 * `imageInfo.rotationDegrees` is what makes the picture upright for the
 * remote side, front or back camera (CameraX accounts for the sensor
 * orientation and lens facing). Pictures are never mirrored here.
 *
 * Used from the main thread only (method channel `lumora/camera`).
 */
object CameraCapture {
    private const val TAG = "CameraCapture"
    /** `lumora_push_camera_yuv` flag: full-range levels (YUV_420_888 is JPEG range). */
    private const val FULL_RANGE = 0x10000

    /** Camera lifecycle independent of the Activity: the call decides when it runs. */
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val main = Handler(Looper.getMainLooper())
    private var provider: ProcessCameraProvider? = null
    private var owner: Owner? = null
    private var camera: Camera? = null
    private var analysis: ImageAnalysis? = null
    private var executor: ExecutorService? = null
    private var orientation: OrientationEventListener? = null
    private var generation = 0

    var facing = "front"
        private set
    val running get() = camera != null

    /** (code, message) — camera lost after start (in use by another app, disabled, error). */
    var onError: ((String, String) -> Unit)? = null

    fun hasPermission(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    /** Cameras by facing, straight from Camera2 (no CameraX init needed). */
    private fun cameraIds(ctx: Context): Map<String, String> {
        val out = linkedMapOf<String, String>()
        try {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            for (id in cm.cameraIdList) {
                val f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
                // USB cameras (LENS_FACING_EXTERNAL) are left out: CameraX only
                // selects them through an experimental API.
                val key = when (f) {
                    CameraCharacteristics.LENS_FACING_FRONT -> "front"
                    CameraCharacteristics.LENS_FACING_BACK -> "back"
                    else -> continue
                }
                out.putIfAbsent(key, id)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "camera list failed: $t")
        }
        return out
    }

    fun supported(ctx: Context) = LumoraNative.available && cameraIds(ctx).isNotEmpty()

    fun cameraCount(ctx: Context) = cameraIds(ctx).size

    /**
     * Start (or move to [want]) and report `{ok, facing, cameras, error?}` once
     * the camera is bound. `error`: permission | no_camera | busy | failed |
     * cancelled (stop/another start came first).
     */
    fun start(ctx: Context, want: String, reply: (Map<String, Any?>) -> Unit) {
        val app = ctx.applicationContext
        val ids = cameraIds(app)
        fun fail(code: String) = reply(mapOf("ok" to false, "error" to code, "facing" to facing, "cameras" to ids.size))
        if (!LumoraNative.available) return fail("failed")
        if (!hasPermission(app)) return fail("permission")
        if (ids.isEmpty()) return fail("no_camera")
        val pick = when {
            ids.containsKey(want) -> want
            ids.containsKey("front") -> "front"
            else -> ids.keys.first()
        }
        if (running && pick == facing) {
            reply(mapOf("ok" to true, "facing" to facing, "cameras" to ids.size))
            return
        }
        val gen = ++generation
        val future = ProcessCameraProvider.getInstance(app)
        future.addListener({
            // Stopped (or restarted) meanwhile: answer anyway so the caller
            // never waits forever, but leave the camera alone.
            if (gen != generation) return@addListener fail("cancelled")
            try {
                val p = future.get()
                provider = p
                bind(app, p, pick, ids[pick])
                facing = pick
                reply(mapOf("ok" to true, "facing" to pick, "cameras" to ids.size))
            } catch (t: Throwable) {
                Log.w(TAG, "camera start failed: $t")
                release()
                val msg = t.toString()
                fail(if (msg.contains("in use", true) || msg.contains("MAX_CAMERAS", true)) "busy" else "failed")
            }
        }, ContextCompat.getMainExecutor(app))
    }

    /** Front ↔ back (or the next camera). */
    fun switch(ctx: Context, reply: (Map<String, Any?>) -> Unit) {
        val ids = cameraIds(ctx.applicationContext).keys.toList()
        if (!running || ids.size < 2) {
            reply(mapOf("ok" to running, "facing" to facing, "cameras" to ids.size))
            return
        }
        val next = ids[(ids.indexOf(facing) + 1) % ids.size]
        start(ctx, next, reply)
    }

    fun stop() {
        generation++
        release()
    }

    private fun release() {
        val wasRunning = camera != null
        orientation?.disable()
        orientation = null
        // Only our own use case: ProcessCameraProvider is process-wide and
        // shared with mobile_scanner (QR preview when linking a device);
        // unbindAll() would kill its preview too.
        analysis?.let { a -> try { provider?.unbind(a) } catch (_: Throwable) {} }
        owner?.registry?.currentState = Lifecycle.State.DESTROYED
        owner = null
        analysis?.clearAnalyzer()
        analysis = null
        camera = null
        executor?.shutdown()
        executor = null
        // Foreground service: drop the `camera` type.
        if (wasRunning) LumoraService.refresh()
    }

    /** Pick a 30 fps AE range: prefer [15..24, 30] (keeps low light usable), else [30, 30]. */
    private fun fpsRange(ctx: Context, id: String?): Range<Int>? {
        if (id == null) return null
        return try {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val ranges = cm.getCameraCharacteristics(id).get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: return null
            ranges.filter { it.upper == 30 && it.lower in 15..24 }.maxByOrNull { it.lower }
                ?: ranges.firstOrNull { it.upper == 30 && it.lower == 30 }
        } catch (_: Throwable) {
            null
        }
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bind(ctx: Context, p: ProcessCameraProvider, pick: String, id: String?) {
        // Moving to another camera: drop the old use case first.
        release()
        val o = Owner().also { it.registry.currentState = Lifecycle.State.RESUMED }
        owner = o
        val exec = Executors.newSingleThreadExecutor { r -> Thread(r, "lumora-camera").apply { priority = Thread.NORM_PRIORITY + 1 } }
        executor = exec

        val resolution = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
            .build()
        val builder = ImageAnalysis.Builder()
            .setResolutionSelector(resolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .setTargetRotation(Surface.ROTATION_0)
        fpsRange(ctx, id)?.let { Camera2Interop.Extender(builder).setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
        val a = builder.build()
        a.setAnalyzer(exec) { img ->
            try {
                val pl = img.planes
                if (pl.size >= 3) {
                    LumoraNative.pushCameraYuv(
                        img.width, img.height,
                        pl[0].buffer, pl[0].rowStride,
                        pl[1].buffer, pl[1].rowStride,
                        pl[2].buffer, pl[2].rowStride,
                        pl[1].pixelStride,
                        img.imageInfo.rotationDegrees or FULL_RANGE,
                    )
                }
            } catch (t: Throwable) {
                Log.w(TAG, "push failed: $t")
            } finally {
                img.close()
            }
        }
        analysis = a

        val selector = if (pick == "back") CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        val cam = p.bindToLifecycle(o, selector, a)
        camera = cam
        // Foreground service: add the `camera` type (keeps the call camera
        // allowed if the UI goes to the background mid-switch).
        LumoraService.refresh()
        val gen = generation
        cam.cameraInfo.cameraState.observe(o) { st ->
            val e = st.error ?: return@observe
            if (gen != generation) return@observe
            val code = when (e.code) {
                CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE -> "busy"
                CameraState.ERROR_CAMERA_DISABLED -> "permission"
                else -> "failed"
            }
            // Recoverable errors are retried by CameraX itself; only report the
            // ones the user has to act on (or that end the stream).
            if (e.type == CameraState.ErrorType.CRITICAL || code == "busy") {
                main.post {
                    if (gen != generation) return@post
                    // Release so "Try again" really re-opens the device (a
                    // bound-but-dead camera would answer `start` with ok).
                    stop()
                    onError?.invoke(code, "camera error ${e.code}")
                }
            }
        }

        // Physical orientation → target rotation (the UI itself may not rotate).
        orientation = object : OrientationEventListener(ctx) {
            override fun onOrientationChanged(deg: Int) {
                if (deg == ORIENTATION_UNKNOWN) return
                val r = when (deg) {
                    in 45 until 135 -> Surface.ROTATION_270
                    in 135 until 225 -> Surface.ROTATION_180
                    in 225 until 315 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
                analysis?.let { if (it.targetRotation != r) it.targetRotation = r }
            }
        }.also { if (it.canDetectOrientation()) it.enable() }
    }
}
