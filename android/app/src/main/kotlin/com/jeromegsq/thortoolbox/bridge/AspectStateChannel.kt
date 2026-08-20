package com.jeromegsq.thortoolbox.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import com.jeromegsq.thortoolbox.aspect.DisplayWatchService
import io.flutter.plugin.common.EventChannel

/**
 * The 4:3 screen's live state, straight from the watch service.
 *
 * The service already broadcasts on every hotplug; this only forwards it, and
 * the receiver exists exactly while a Dart listener does — the same lifetime the
 * old section gave it between onResume and onPause.
 */
class AspectStateChannel(private val context: Context) : EventChannel.StreamHandler {

    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                events.success(
                    mapOf(
                        "external" to intent.getBooleanExtra(
                            DisplayWatchService.EXTRA_EXTERNAL, false
                        ),
                        "applied" to intent.getBooleanExtra(
                            DisplayWatchService.EXTRA_APPLIED, false
                        ),
                    )
                )
            }
        }

        val filter = IntentFilter(DisplayWatchService.ACTION_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(r, filter)
        }
        receiver = r
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { context.unregisterReceiver(it) }
        receiver = null
    }
}
