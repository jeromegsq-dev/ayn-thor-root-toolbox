package com.jeromegsq.thortoolbox.gamepad

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class GameProfilesBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // Only start when the feature is actually on: nothing here should ask
        // for superuser access on every boot for a feature nobody enabled.
        if (Intent.ACTION_BOOT_COMPLETED == intent.action && GameProfiles.enabled(context)) {
            GameProfileService.start(context)
        }
    }
}
