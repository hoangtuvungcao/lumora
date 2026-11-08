package vn.lumora.lumora

import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * Chat bubbles on Xiaomi / Redmi / POCO (MIUI, HyperOS).
 *
 * Their bubble container only starts an app's bubble Activity when the app may "display
 * pop-up windows while running in the background" (MIUI app-op 10021) AND "display over
 * other apps" (SYSTEM_ALERT_WINDOW). Without both, the bubble opens as an empty grey box
 * (its task is never started, nothing is logged) — and it stays broken even after the
 * permissions are given, until a new bubble is made. Seen on a Redmi Note 12, HyperOS 2.0
 * (Android 15): with both allowed, the same bubble Activity opens normally.
 *
 * So on these phones a chat is offered as a bubble only once both are allowed, and
 * Settings › Notifications › Chat bubbles shows how to allow them ([open]).
 */
object OemPopups {
    /** MIUI's "display pop-up windows while running in the background" app-op. */
    private const val OP_BACKGROUND_START_ACTIVITY = 10021
    /** MIUI's "show on lock screen" app-op (an incoming call over the lock screen). */
    private const val OP_SHOW_WHEN_LOCKED = 10020

    fun isXiaomi(): Boolean {
        val brand = (Build.MANUFACTURER + " " + Build.BRAND).lowercase()
        return listOf("xiaomi", "redmi", "poco").any { it in brand }
    }

    /** Bubbles can't open on this phone until the user allows Lumora's pop-ups. */
    fun bubblesBlocked(ctx: Context): Boolean = isXiaomi() && !(Settings.canDrawOverlays(ctx) && miuiPopupsAllowed(ctx))

    private fun miuiPopupsAllowed(ctx: Context): Boolean = miuiOp(ctx, OP_BACKGROUND_START_ACTIVITY)

    private fun miuiOp(ctx: Context, op: Int): Boolean = runCatching {
        val ops = ctx.getSystemService(AppOpsManager::class.java)
        val m = AppOpsManager::class.java.getMethod("checkOpNoThrow", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
        m.invoke(ops, op, ctx.applicationInfo.uid, ctx.packageName) as Int == AppOpsManager.MODE_ALLOWED
    }.getOrDefault(true) // can't tell (not MIUI after all): don't hold anything back

    /** Android 14+: an incoming call may take the whole (locked) screen. */
    fun fullScreenAllowed(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 34 || ctx.getSystemService(android.app.NotificationManager::class.java).canUseFullScreenIntent()

    /**
     * For Dart (Settings › background sheet): `fullScreen` (calls over the lock screen,
     * Android 14+), and on Xiaomi `xiaomi` + `popups` (pop-ups in the background, over other
     * apps and on the lock screen — chat bubbles and calls need them).
     */
    fun status(ctx: Context): Map<String, Boolean> = mapOf(
        "fullScreen" to fullScreenAllowed(ctx),
        "xiaomi" to isXiaomi(),
        "popups" to (!isXiaomi() || Settings.canDrawOverlays(ctx) && miuiOp(ctx, OP_BACKGROUND_START_ACTIVITY) && miuiOp(ctx, OP_SHOW_WHEN_LOCKED)),
    )

    /** Android 14+: Lumora's own "full-screen notifications" switch, one tap away. */
    fun openFullScreen(a: Activity) {
        if (Build.VERSION.SDK_INT >= 34 && runCatching {
                a.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${a.packageName}")))
            }.isSuccess) return
        runCatching { a.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${a.packageName}"))) }
    }

    /** Opens Lumora's permission page (MIUI's editor; else the overlay page; else app info). */
    fun open(a: Activity) {
        val pkg = a.packageName
        val tries = listOf(
            Intent("miui.intent.action.APP_PERM_EDITOR")
                .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                .putExtra("extra_pkgname", pkg),
            Intent("miui.intent.action.APP_PERM_EDITOR").putExtra("extra_pkgname", pkg),
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$pkg")),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")),
        )
        for (i in tries) {
            if (runCatching { a.startActivity(i) }.isSuccess) return
        }
    }
}
