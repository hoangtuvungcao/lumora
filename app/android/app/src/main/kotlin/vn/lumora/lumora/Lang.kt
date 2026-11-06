package vn.lumora.lumora

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * The app's own language (Settings → Ngôn ngữ, `vi` | `en`), which may differ
 * from the phone's. Everything the system shows on our behalf outside the
 * Flutter UI — notifications, notification channel names, the foreground
 * service notification, the accessibility guide — is resolved through
 * [context] so it matches the language the user picked in Lumora.
 *
 * Set from Dart over `lumora/service.setLanguage {lang}` and persisted, so a
 * service restarted without the UI still speaks the right language.
 */
object Lang {
    private const val PREFS = "lumora_lang"
    private const val KEY = "lang"

    @Volatile private var cached: String? = null

    /** "vi", "en" or "" (not set yet: follow the phone). */
    fun get(ctx: Context): String {
        cached?.let { return it }
        val v = try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "") ?: ""
        } catch (_: Throwable) {
            ""
        }
        cached = v
        return v
    }

    /** Returns true when the language changed. */
    fun set(ctx: Context, lang: String?): Boolean {
        val l = when (lang) {
            "vi", "en" -> lang
            else -> ""
        }
        if (l == get(ctx)) return false
        cached = l
        try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, l).apply()
        } catch (_: Throwable) {
        }
        return true
    }

    /** [ctx] with its resources switched to the app's language. */
    fun context(ctx: Context): Context {
        val l = get(ctx)
        if (l.isEmpty()) return ctx
        val cur = ctx.resources.configuration
        if (cur.locales.size() > 0 && cur.locales[0].language == l) return ctx
        val conf = Configuration(cur)
        conf.setLocale(Locale.forLanguageTag(l))
        return try {
            ctx.createConfigurationContext(conf)
        } catch (_: Throwable) {
            ctx
        }
    }

    /** Shorthand: a string in the app's language. */
    fun str(ctx: Context, id: Int): String = context(ctx).getString(id)
}
