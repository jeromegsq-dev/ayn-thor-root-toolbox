package com.jeromegsq.thortoolbox.aspect;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        // Only start when the tool is actually on: an app that also hosts the
        // root-free AutoDim screen must not ask for superuser access on every
        // boot for a feature nobody enabled.
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())
                && Settings.enabled(context)) {
            DisplayWatchService.start(context);
        }
    }
}
