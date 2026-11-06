package vn.lumora.lumora

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Onboarding for remote control on Android: explains (vi/en via resources,
 * in the app's language — [Lang]) why Lumora needs an Accessibility service
 * and how to switch it on.
 * Closes itself as soon as the service is enabled.
 */
class AccessibilityGuideActivity : Activity() {
    private lateinit var status: TextView

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val dark get() = (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
        android.content.res.Configuration.UI_MODE_NIGHT_YES
    private val fg get() = if (dark) Color.parseColor("#E8ECF4") else Color.parseColor("#141A2B")
    private val muted get() = if (dark) Color.parseColor("#A3ACBF") else Color.parseColor("#5B6478")
    private val bg get() = if (dark) Color.parseColor("#0F1020") else Color.WHITE
    private val card get() = if (dark) Color.parseColor("#171A2E") else Color.parseColor("#F3F5FA")
    private val accent = Color.parseColor("#6C5CE7")

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(Lang.context(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView // installs the decor so insetsController is available
        @Suppress("DEPRECATION")
        window.statusBarColor = bg
        if (!dark) {
            // dark status-bar icons on the light background
            if (Build.VERSION.SDK_INT >= 30) {
                window.insetsController?.setSystemBarsAppearance(
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                )
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(28), dp(22), dp(28))
            setBackgroundColor(bg)
        }
        fun text(s: CharSequence, size: Float, color: Int, bold: Boolean = false, top: Int = 0) = TextView(this).apply {
            text = s
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setLineSpacing(0f, 1.25f)
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
        }
        root.addView(text(getString(R.string.a11y_title), 24f, fg, bold = true))
        root.addView(text(getString(R.string.a11y_why), 15f, muted, top = 10))

        val steps = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(card) }
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(20) }
        }
        steps.addView(text(getString(R.string.a11y_steps_title), 16f, fg, bold = true))
        listOf(R.string.a11y_step1, R.string.a11y_step2, R.string.a11y_step3, R.string.a11y_step4).forEachIndexed { i, id ->
            steps.addView(text("${i + 1}.  " + getString(id), 15f, fg, top = 8))
        }
        root.addView(steps)

        root.addView(text(getString(R.string.a11y_restricted), 13.5f, muted, top = 14))
        root.addView(text(getString(R.string.a11y_privacy), 13.5f, muted, top = 10))

        status = text("", 15f, accent, bold = true, top = 18)
        root.addView(status)

        fun button(label: String, primary: Boolean, onClick: () -> Unit) = Button(this).apply {
            text = label
            isAllCaps = false
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(if (primary) Color.WHITE else accent)
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                if (primary) setColor(accent) else { setColor(Color.TRANSPARENT); setStroke(dp(1), accent) }
            }
            stateListAnimator = null
            layoutParams = LinearLayout.LayoutParams(-1, dp(52)).apply { topMargin = dp(12) }
            setOnClickListener { onClick() }
        }
        root.addView(button(getString(R.string.a11y_open_settings), true) {
            try { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) } catch (_: Throwable) {}
        })
        root.addView(button(getString(R.string.a11y_open_app_info), false) {
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            } catch (_: Throwable) {}
        })
        root.addView(button(getString(R.string.a11y_later), false) { finish() })

        val scroll = ScrollView(this).apply {
            setBackgroundColor(bg)
            isFillViewport = true
            addView(root)
        }
        if (Build.VERSION.SDK_INT >= 30) {
            scroll.setOnApplyWindowInsetsListener { v, insets ->
                val sb = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                v.setPadding(0, sb.top, 0, sb.bottom)
                insets
            }
        }
        scroll.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        root.gravity = Gravity.TOP
        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        if (LumoraAccessibilityService.isEnabled(this)) {
            status.text = getString(R.string.a11y_enabled)
            status.postDelayed({ if (!isFinishing) finish() }, 900)
        } else {
            status.text = ""
        }
    }
}
