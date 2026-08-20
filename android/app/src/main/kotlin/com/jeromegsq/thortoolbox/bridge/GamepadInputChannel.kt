package com.jeromegsq.thortoolbox.bridge

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.plugin.common.EventChannel

/**
 * The merged controller as Android hands it to the app in front — which is
 * exactly what a game gets.
 *
 * Deliberately not the daemon's `--watch` stream: that reports what the physical
 * pads sent, *before* the profiles are applied. The preview has to answer "what
 * comes out", so it reads the end of the chain rather than the start, and needs
 * no root to do it.
 *
 * Events are swallowed while a listener is attached, so pushing a stick moves
 * the on-screen stick instead of moving the focus around underneath it. Back is
 * the exception: consuming it would leave the preview with no way out for
 * someone driving the device by pad.
 */
class GamepadInputChannel : EventChannel.StreamHandler {

    private var events: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        this.events = events
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    /** True when the event was taken and must not travel any further. */
    fun onKeyEvent(event: KeyEvent): Boolean {
        val sink = events ?: return false
        if (!isFromGamepad(event.device, event.source)) {
            return false
        }
        // A held button repeats; the preview already shows it as down.
        if (event.repeatCount == 0) {
            sink.success(
                mapOf(
                    "kind" to "key",
                    "name" to KeyEvent.keyCodeToString(event.keyCode),
                    "code" to event.keyCode,
                    // A cancelled event is the system taking a press back — the
                    // button is not held, whatever its action says.
                    "down" to (event.action == KeyEvent.ACTION_DOWN && !event.isCanceled),
                    "device" to (event.device?.name ?: ""),
                )
            )
        }
        return event.keyCode != KeyEvent.KEYCODE_BACK
    }

    fun onMotionEvent(event: MotionEvent): Boolean {
        val sink = events ?: return false
        if (!isFromGamepad(event.device, event.source)) {
            return false
        }
        if (event.action != MotionEvent.ACTION_MOVE) {
            return false
        }
        sink.success(
            mapOf(
                "kind" to "motion",
                "axes" to AXES.mapValues { (_, axis) -> event.getAxisValue(axis).toDouble() },
                "device" to (event.device?.name ?: ""),
            )
        )
        return true
    }

    /**
     * The device counts as much as the event: a button remapped to
     * `KEY_VOLUMEUP` arrives with a keyboard source but comes off the pad, and
     * the whole point of the preview is that it shows up too. Taking either
     * also lets `adb shell input gamepad keyevent` through, which is the only
     * way to exercise this without hands on the device.
     *
     * A d-pad has to be named separately. Its presses arrive as plain
     * directional keys whose source is SOURCE_DPAD and nothing else — no
     * gamepad, no joystick — so a check for those two alone let the whole
     * d-pad through to the widget tree, where Flutter took it for focus
     * navigation. The system's own virtual keyboard carries SOURCE_DPAD too,
     * and is the one thing here that is not a controller.
     */
    private fun isFromGamepad(device: InputDevice?, source: Int): Boolean {
        if (device?.isVirtual == true) {
            return false
        }
        val sources = (device?.sources ?: 0) or source
        return sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK ||
            sources and InputDevice.SOURCE_DPAD == InputDevice.SOURCE_DPAD
    }

    private companion object {
        /**
         * These pads follow the modern evdev convention: the right stick is
         * Z/RZ and the triggers are GAS/BRAKE. RX/RY and L/RTRIGGER are read
         * anyway, so a pad wired the older way still shows up.
         */
        val AXES = mapOf(
            "AXIS_X" to MotionEvent.AXIS_X,
            "AXIS_Y" to MotionEvent.AXIS_Y,
            "AXIS_Z" to MotionEvent.AXIS_Z,
            "AXIS_RZ" to MotionEvent.AXIS_RZ,
            "AXIS_RX" to MotionEvent.AXIS_RX,
            "AXIS_RY" to MotionEvent.AXIS_RY,
            "AXIS_HAT_X" to MotionEvent.AXIS_HAT_X,
            "AXIS_HAT_Y" to MotionEvent.AXIS_HAT_Y,
            "AXIS_BRAKE" to MotionEvent.AXIS_BRAKE,
            "AXIS_GAS" to MotionEvent.AXIS_GAS,
            "AXIS_LTRIGGER" to MotionEvent.AXIS_LTRIGGER,
            "AXIS_RTRIGGER" to MotionEvent.AXIS_RTRIGGER,
        )
    }
}
