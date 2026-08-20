package com.jeromegsq.thortoolbox.bridge

import android.app.Activity
import android.content.Context
import com.jeromegsq.thortoolbox.nso.NsoGamepad
import io.flutter.plugin.common.EventChannel

/**
 * Everything the NSO GameCube pad reports — scan results, the bring-up log, the
 * attributes it exposes, and its input once it starts talking.
 *
 * One stream rather than a method channel per action because the whole screen is
 * a running commentary on a sequence that either works or says where it stopped;
 * the two commands it takes travel as arguments on the subscription instead.
 */
class NsoChannel(private val context: Context) : EventChannel.StreamHandler {

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val missing = NsoGamepad.missingPermissions(context)
        if (missing.isNotEmpty()) {
            // Asked for here rather than at startup: these are only ever needed by
            // this one screen, and a launcher that demands Bluetooth on first boot
            // to show a grid of tiles has asked for the wrong thing.
            (context as? Activity)?.requestPermissions(missing.toTypedArray(), 2)
            events.success(
                mapOf(
                    "kind" to "error",
                    "message" to "Bluetooth permission needed — grant it, then scan again",
                ),
            )
            return
        }

        val args = arguments as? Map<*, *>
        val pad = NsoGamepad.get(context)
        pad.listener = { events.success(it) }
        pad.publish = args?.get("publish") as? Boolean ?: true

        // Four ways in: an address connects to that pad, `auto` scans and then
        // connects to whatever turns out to be the pad, `watch` attaches to
        // whatever is already running without disturbing it, and a bare
        // subscription only scans.
        val address = args?.get("address") as? String
        val watch = args?.get("watch") as? Boolean ?: false
        val auto = args?.get("auto") as? Boolean ?: false
        when {
            address != null -> pad.connect(address)
            auto -> pad.autoConnect()
            watch -> Unit
            else -> pad.startScan()
        }
    }

    /**
     * Detaches the screen and nothing else.
     *
     * Closing the diagnostic page used to take the pad down with it — the stack
     * logged it as `reason=0x16`, terminated by local host — which is precisely
     * backwards for a controller: it is most needed once this app is out of the
     * way. Only [NsoGamepad.disconnect] ends a session now.
     */
    override fun onCancel(arguments: Any?) {
        NsoGamepad.get(context).listener = null
    }

}
