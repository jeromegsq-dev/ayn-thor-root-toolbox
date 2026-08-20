package com.jeromegsq.thortoolbox.bridge

import android.os.Handler
import android.os.Looper
import com.jeromegsq.thortoolbox.gamepad.Gpmerge
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Raw `gpmerge --watch` output while the user is being asked to press something.
 *
 * The lines go over untouched: deciding that a button was pressed, or that a
 * stick has travelled far enough to count, is judgement about what the user
 * meant rather than platform work, so it lives on the Dart side in
 * `lib/src/gamepad/watch.dart`.
 *
 * Cancelling the Dart subscription kills the root process, so nothing survives
 * a dismissed dialog.
 */
class GamepadWatchChannel : EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)
    private var proc: Process? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        cancelled.set(false)
        val seconds = (arguments as? Map<*, *>)?.get("seconds") as? Int ?: 20
        proc = Gpmerge.watch(
            seconds,
            onLine = { line ->
                if (!cancelled.get()) {
                    main.post { if (!cancelled.get()) events.success(line) }
                }
            },
            onEnd = {
                main.post { if (!cancelled.get()) events.endOfStream() }
            },
        )
    }

    override fun onCancel(arguments: Any?) {
        cancelled.set(true)
        proc?.destroyForcibly()
        proc = null
    }
}
