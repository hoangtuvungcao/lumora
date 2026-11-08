package vn.lumora.lumora

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * Call audio routing. The core plays call audio as a voice-communication stream
 * (patched cpal); here the phone goes into communication mode for the call and the
 * output is the loudspeaker or the earpiece. A headset or Bluetooth device, when
 * connected, takes the sound instead of the earpiece (and of the loudspeaker for
 * video calls, which start on the loudspeaker).
 */
object CallAudio {
    private var active = false
    private var speaker = false

    private fun am(ctx: Context) = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun start(ctx: Context, video: Boolean) {
        val am = am(ctx)
        active = true
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        route(ctx, video && !hasHeadset(am))
    }

    fun setSpeaker(ctx: Context, on: Boolean) {
        if (!active) start(ctx, false)
        route(ctx, on)
    }

    fun end(ctx: Context) {
        if (!active) return
        active = false
        speaker = false
        val am = am(ctx)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
        }
        am.mode = AudioManager.MODE_NORMAL
    }

    /** Whether the sound is on the loudspeaker now (the button state). */
    fun isSpeaker(): Boolean = speaker

    private fun route(ctx: Context, on: Boolean) {
        val am = am(ctx)
        speaker = on
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = am.availableCommunicationDevices
            val want = if (on) {
                devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            } else {
                // a headset / Bluetooth first, else the earpiece
                devices.firstOrNull { it.type in HEADSETS } ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
            }
            if (want != null) am.setCommunicationDevice(want) else am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = on
        }
    }

    private fun hasHeadset(am: AudioManager): Boolean =
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in HEADSETS }

    private val HEADSETS = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
    )
}
