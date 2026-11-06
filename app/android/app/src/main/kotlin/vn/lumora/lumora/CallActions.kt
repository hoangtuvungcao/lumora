package vn.lumora.lumora

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * "Từ chối" (Decline) on the incoming-call notification ([Notifier.show], kind
 * "call"). The ringing stops and the notification goes at once; Dart declines
 * the call in the core ([LumoraEngine.callAction]). "Trả lời" (Answer) opens
 * Lumora instead (MainActivity, over the lock screen): answering needs the
 * microphone permission and shows the call screen.
 */
class CallActions : BroadcastReceiver() {
    companion object {
        const val DECLINE = "vn.lumora.CALL_DECLINE"
        const val EXTRA_CALL_ID = "vn.lumora.CALL_ID"
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != DECLINE) return
        val app = ctx.applicationContext
        Notifier.cancel(app, "call")
        CallTones.stop(app)
        LumoraEngine.callAction("decline", intent.getStringExtra(EXTRA_CALL_ID) ?: "")
    }
}
