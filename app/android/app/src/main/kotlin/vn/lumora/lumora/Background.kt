package vn.lumora.lumora

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * Staying reachable in the background. Lumora has no push server: the
 * foreground service keeps the connection, but Android's battery
 * optimisation (Doze, app standby) and OEM "battery savers" still freeze or
 * kill it — no messages, no calls until the app is opened again.
 *
 *  - [requestIgnoreBattery]: the system "Allow Lumora to always run in the
 *    background?" dialog (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS). Google Play
 *    allows it for messaging/calling apps that cannot use push (FCM).
 *  - [openAutostart]: Xiaomi/Redmi/POCO (MIUI, HyperOS) and some other OEMs
 *    also need "Autostart" (and their own battery saver set to
 *    "No restrictions"), or they kill Lumora when it is swiped away and never
 *    let it restart. Their settings screens are private activities: the known
 *    ones are tried in turn, then the app's details page.
 */
object Background {
    private const val TAG = "LumoraBackground"

    private fun oem(): String {
        val m = (Build.MANUFACTURER ?: "").lowercase()
        val b = (Build.BRAND ?: "").lowercase()
        return when {
            listOf("xiaomi", "redmi", "poco").any { m.contains(it) || b.contains(it) } -> "xiaomi"
            listOf("oppo", "realme", "oneplus").any { m.contains(it) || b.contains(it) } -> "oppo"
            listOf("vivo", "iqoo").any { m.contains(it) || b.contains(it) } -> "vivo"
            listOf("huawei", "honor").any { m.contains(it) || b.contains(it) } -> "huawei"
            m.contains("samsung") -> "samsung"
            else -> ""
        }
    }

    /** Settings screens of each OEM's autostart / background manager, most specific first. */
    private val autostart: Map<String, List<ComponentName>> = mapOf(
        "xiaomi" to listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.miui.securitycenter", "com.miui.powercenter.PowerSettings"),
        ),
        "oppo" to listOf(
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        ),
        "vivo" to listOf(
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
        ),
        "huawei" to listOf(
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ),
    )

    fun ignoringBattery(ctx: Context): Boolean = try {
        (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(ctx.packageName)
    } catch (_: Throwable) {
        false
    }

    /** For Dart: `{ignoring, oem, autostart}` (autostart: an OEM screen worth showing). */
    fun status(ctx: Context): Map<String, Any> {
        val o = oem()
        return mapOf("ignoring" to ignoringBattery(ctx), "oem" to o, "autostart" to autostart.containsKey(o))
    }

    private fun launch(ctx: Context, i: Intent): Boolean = try {
        if (ctx !is Activity) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
        true
    } catch (t: Throwable) {
        Log.i(TAG, "cannot open ${i.component ?: i.action}: $t")
        false
    }

    private fun appDetails(ctx: Context) =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))

    /** true: a settings screen opened (the answer comes back via [status] on resume). */
    @SuppressLint("BatteryLife") // a P2P messenger without push: allowed by Play policy
    fun requestIgnoreBattery(ctx: Context): Boolean {
        if (ignoringBattery(ctx)) return true
        return launch(ctx, Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))) ||
            launch(ctx, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) ||
            launch(ctx, appDetails(ctx))
    }

    fun openAutostart(ctx: Context): Boolean {
        for (c in autostart[oem()].orEmpty()) {
            if (launch(ctx, Intent().setComponent(c))) return true
        }
        return launch(ctx, appDetails(ctx))
    }
}
