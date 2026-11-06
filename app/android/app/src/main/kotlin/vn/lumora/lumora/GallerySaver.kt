package vn.lumora.lumora

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * "Lưu về máy" for photos (`lumora/media.saveToGallery`).
 *
 * Android 10+: MediaStore insert into Pictures/Lumora - no storage permission.
 * Android 8–9: the app's own Pictures folder (no permission either), handed to
 * the media scanner so gallery apps index it.
 */
object GallerySaver {
    fun save(context: Context, bytes: ByteArray, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Lumora")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            try {
                val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("Cannot open $uri")
                out.use { it.write(bytes) }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (t: Throwable) {
                resolver.delete(uri, null, null)
                throw t
            }
            return uri.toString()
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_PICTURES), "Lumora").apply { mkdirs() }
        val stem = name.substringBeforeLast('.')
        val ext = name.substringAfterLast('.', "jpg")
        var f = File(dir, name)
        var i = 2
        while (f.exists()) {
            f = File(dir, "${stem}_$i.$ext")
            i++
        }
        f.writeBytes(bytes)
        MediaScannerConnection.scanFile(context, arrayOf(f.absolutePath), arrayOf(mime), null)
        return f.absolutePath
    }

    /**
     * "Lưu" for any received file (`lumora/media.saveToDownloads`): a copy in the
     * public Download/Lumora folder, where the Files app and other apps see it.
     * Received files live in the app's own external folder (Android/data/…),
     * which users cannot browse on Android 11+.
     *
     * Android 10+: MediaStore.Downloads insert, no storage permission (the
     * system picks a free name if one is taken). Android 8–9: public
     * Download/Lumora needs WRITE_EXTERNAL_STORAGE, which Lumora does not ask
     * for, so null is returned and the caller keeps its fallback.
     * Returns the user-facing location ("Download/Lumora/<name>").
     */
    fun saveToDownloads(context: Context, path: String, name: String): String? {
        if (Build.VERSION.SDK_INT < 29) return null
        val mime = android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Lumora")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        try {
            val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("Cannot open $uri")
            out.use { o -> File(path).inputStream().use { it.copyTo(o, 1 shl 16) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (t: Throwable) {
            resolver.delete(uri, null, null)
            throw t
        }
        // The name actually used (MediaStore adds " (1)" when taken).
        val shown = resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: name
        return Environment.DIRECTORY_DOWNLOADS + "/Lumora/" + shown
    }

    /**
     * HEIC/HEIF (camera default on many phones) → JPEG q92, EXIF orientation
     * applied, no metadata copied (so no GPS). Long side capped at [maxSide]
     * when > 0. Null when the device can't decode it (Android < 9 has no
     * HEIF decoder).
     */
    fun heicToJpeg(path: String, maxSide: Int): ByteArray? {
        val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= 28) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(File(path))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val w = info.size.width
                val h = info.size.height
                val long = max(w, h)
                if (maxSide in 1 until long) {
                    val s = maxSide.toDouble() / long
                    decoder.setTargetSize(max(1, (w * s).roundToInt()), max(1, (h * s).roundToInt()))
                }
            }
        } else {
            BitmapFactory.decodeFile(path) ?: return null
        }
        return try {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
            out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }
}
