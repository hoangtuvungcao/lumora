package vn.lumora.lumora

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

/**
 * Opens a received / sent file in another app. Android (7+) refuses file:// URIs, so the
 * file goes through our FileProvider as a content:// URI with a read grant for that one file.
 */
object FileOpener {
    /** false: no file, or no app on the phone opens this kind of file. */
    fun open(ctx: Context, path: String): Boolean {
        val f = File(path)
        if (!f.isFile) return false
        val uri = try {
            FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
        } catch (_: IllegalArgumentException) {
            return false // outside the shared folders
        }
        val ext = f.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(view, null).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            if (view.resolveActivity(ctx.packageManager) == null && mime != "*/*") {
                // nothing for this type: let the user pick any app
                view.setDataAndType(uri, "*/*")
            }
            ctx.startActivity(chooser)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
