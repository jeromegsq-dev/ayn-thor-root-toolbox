package com.jeromegsq.thortoolbox.aspect;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.util.Log;
import android.view.Display;

import com.jeromegsq.thortoolbox.MainActivity;
import com.jeromegsq.thortoolbox.Props;
import com.jeromegsq.thortoolbox.R;

import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

/**
 * Watches for an external screen and holds the top screen in 4:3 for as long as
 * one is connected.
 *
 * The external output mirrors the top screen (same layer stack), so the two
 * cannot be given different ratios: forcing 4:3 on the VGA output means forcing
 * 4:3 on display 0, which then appears stretched on the internal 16:9 panel.
 * That is an accepted trade-off, not a bug.
 */
public class DisplayWatchService extends Service {

    private static final String TAG = Root.TAG;
    private static final String CHANNEL = "watch";
    private static final int NOTIF_ID = 1;

    /** A hotplug fires several events in a row; let them settle. */
    private static final long DEBOUNCE_MS = 800;

    public static final String ACTION_STATE = "com.jeromegsq.thortoolbox.aspect.STATE";
    public static final String EXTRA_EXTERNAL = "external";
    public static final String EXTRA_APPLIED = "applied";

    private DisplayManager dm;
    private HandlerThread thread;
    private Handler handler;

    /** Last state pushed to the device; null until something has been applied. */
    private Boolean applied;

    private final Runnable syncTask = this::sync;

    private final DisplayManager.DisplayListener listener = new DisplayManager.DisplayListener() {
        @Override
        public void onDisplayAdded(int displayId) {
            schedule();
        }

        @Override
        public void onDisplayRemoved(int displayId) {
            schedule();
        }

        @Override
        public void onDisplayChanged(int displayId) {
            // Our own `wm size` on display 0 lands here too. sync() is
            // idempotent, so it will not re-apply anything.
            schedule();
        }
    };

    public static void start(Context c) {
        c.startForegroundService(new Intent(c, DisplayWatchService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        enterForeground(getString(R.string.aspect_notif_starting));

        thread = new HandlerThread("display-watch");
        thread.start();
        handler = new Handler(thread.getLooper());

        dm = getSystemService(DisplayManager.class);
        dm.registerDisplayListener(listener, handler);

        handler.post(this::applyDpProps);
        // Covers the cable already being plugged in at startup.
        schedule();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Also runs after the settings screen saves.
        handler.post(this::applyDpProps);
        schedule();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        dm.unregisterDisplayListener(listener);
        thread.quitSafely();
        super.onDestroy();
    }

    private void schedule() {
        handler.removeCallbacks(syncTask);
        handler.postDelayed(syncTask, DEBOUNCE_MS);
    }

    /**
     * Sets the physical mode of the DP output.
     *
     * Done early rather than on connection: the vendor HAL reads these props
     * during the hotplug itself, so writing them once the screen is already
     * registered would be too late for that plug. They are `persist.` props and
     * survive reboots, so writing them once is enough.
     */
    private void applyDpProps() {
        if (!Settings.manageDp(this)) {
            return;
        }
        String mode = Settings.dpMode(this);
        Matcher m = Pattern.compile("(\\d+)x(\\d+)@(\\d+)").matcher(mode);
        if (!m.matches()) {
            Log.w(TAG, "invalid DP mode: " + mode);
            return;
        }

        // Reading props needs no superuser access, so the check runs without one
        // and nothing asks for root while the values are already right.
        String w = m.group(1), h = m.group(2), fps = m.group(3);
        if (w.equals(Props.get("persist.vendor.dp.hdisplay"))
                && h.equals(Props.get("persist.vendor.dp.vdisplay"))
                && fps.equals(Props.get("persist.vendor.dp.fps"))) {
            return;
        }

        String out = Root.run(
                "setprop persist.vendor.dp.hdisplay " + w,
                "setprop persist.vendor.dp.vdisplay " + h,
                "setprop persist.vendor.dp.fps " + fps,
                "setprop persist.vendor.dp.switch true",
                "setprop persist.vendor.dp.select 1");
        Log.i(TAG, out == null ? "failed to set DP props" : "DP output set to " + mode);
    }

    /** Logical size of the DP display itself (extended mode only). */
    private void applyDpLogical(int displayId) {
        String size = Settings.dpLogical(this);
        if (size.isEmpty() || displayId < 0) {
            return;
        }
        Root.run("wm size " + size + " -d " + displayId);
        Log.i(TAG, "DP display " + displayId + " -> " + size);
    }

    /** Brings the device in line with whether an external screen is connected. */
    private void sync() {
        int externalId = externalDisplayId();
        boolean external = externalId >= 0;

        if (!Settings.enabled(this)) {
            // Turned off: hand the screen back, then get out of the way entirely
            // rather than sit in the notification shade holding superuser access.
            if (Boolean.TRUE.equals(applied)) {
                apply(false);
            }
            broadcast(external);
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return;
        }

        if (applied == null || applied != external) {
            apply(external);
            if (external) {
                applyDpLogical(externalId);
            }
        }
        broadcast(external);
        note(external);
    }

    private void apply(boolean fourThree) {
        String out;
        if (fourThree) {
            out = Root.run(
                    "wm size " + Settings.size(this),
                    "wm density " + Settings.density(this));
        } else {
            out = Root.run("wm size reset", "wm density reset");
        }

        if (out == null) {
            Log.w(TAG, "could not apply (superuser denied?)");
            applied = null;
            noteFailure(fourThree);
            return;
        }
        applied = fourThree;
        Log.i(TAG, "applied: " + (fourThree ? "4:3" : "native"));
    }

    /** Id of the connected external display, or -1. */
    private int externalDisplayId() {
        Pattern p;
        try {
            p = Pattern.compile(Settings.pattern(this));
        } catch (PatternSyntaxException e) {
            Log.w(TAG, "invalid pattern, falling back to the default", e);
            p = Pattern.compile(Settings.DEF_PATTERN);
        }

        for (Display d : dm.getDisplays()) {
            if (d.getDisplayId() == Display.DEFAULT_DISPLAY) {
                continue;
            }
            String name = d.getName();
            if (name != null && p.matcher(name).matches()) {
                return d.getDisplayId();
            }
        }
        return -1;
    }

    private void broadcast(boolean external) {
        Intent i = new Intent(ACTION_STATE)
                .setPackage(getPackageName())
                .putExtra(EXTRA_EXTERNAL, external)
                .putExtra(EXTRA_APPLIED, Boolean.TRUE.equals(applied));
        sendBroadcast(i);
    }

    private void note(boolean external) {
        getSystemService(NotificationManager.class).notify(NOTIF_ID,
                notification(getString(external
                        ? R.string.aspect_notif_on
                        : R.string.aspect_notif_off)));
    }

    private void noteFailure(boolean external) {
        String text = getString(external
                ? R.string.aspect_notif_on
                : R.string.aspect_notif_off)
                + " (" + getString(R.string.aspect_notif_root_failed) + ")";
        getSystemService(NotificationManager.class).notify(NOTIF_ID, notification(text));
    }

    private void enterForeground(String text) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notification(text),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIF_ID, notification(text));
        }
    }

    private Notification notification(String text) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(
                CHANNEL, getString(R.string.aspect_channel_name),
                NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);

        PendingIntent pi = PendingIntent.getActivity(
                this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE);

        return new Notification.Builder(this, CHANNEL)
                .setContentTitle(getString(R.string.aspect_title))
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_crop)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
