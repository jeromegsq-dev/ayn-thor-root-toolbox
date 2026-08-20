package com.jeromegsq.thortoolbox.aspect;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Settings shared between the activity and the watch service.
 *
 * Unlike :autodim, everything here is applied by the app itself through
 * superuser access, so nothing has to be handed over to a root daemon and plain
 * SharedPreferences are enough.
 */
public final class Settings {

    private static final String FILE = "thoraspect";

    /**
     * Logical size forced on the top screen while an external screen is
     * connected, in the panel's native (portrait) coordinates: 768x1024 renders
     * as 1024x768 once the device is held in landscape.
     */
    private static final String K_SIZE = "size";
    private static final String K_DENSITY = "density";
    /**
     * The bottom panel ("Screen-2") also carries FLAG_PRESENTATION, so matching
     * external screens on that flag yields a false positive. Match on the name.
     */
    private static final String K_PATTERN = "pattern";
    private static final String K_ENABLED = "enabled";

    /**
     * Physical mode asked of the DisplayPort output. The AYN vendor HAL re-reads
     * these props on every hotplug: this is what avoids the "out of range" on a
     * screen that cannot take the 1080p advertised by the adapter's generic EDID.
     */
    private static final String K_DP_MODE = "dp_mode";
    private static final String K_MANAGE_DP = "manage_dp";
    /** Logical size of the DP display itself. No effect while mirroring. */
    private static final String K_DP_LOGICAL = "dp_logical";

    public static final String DEF_SIZE = "768x1024";
    public static final int DEF_DENSITY = 262;
    public static final String DEF_PATTERN = "(?i).*(dp|hdmi|external).*";
    public static final String DEF_DP_MODE = "1024x768@60";
    public static final String DEF_DP_LOGICAL = "";

    private Settings() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    public static String size(Context c) {
        return sp(c).getString(K_SIZE, DEF_SIZE);
    }

    public static int density(Context c) {
        return sp(c).getInt(K_DENSITY, DEF_DENSITY);
    }

    public static String pattern(Context c) {
        return sp(c).getString(K_PATTERN, DEF_PATTERN);
    }

    public static boolean enabled(Context c) {
        return sp(c).getBoolean(K_ENABLED, true);
    }

    public static String dpMode(Context c) {
        return sp(c).getString(K_DP_MODE, DEF_DP_MODE);
    }

    public static boolean manageDp(Context c) {
        return sp(c).getBoolean(K_MANAGE_DP, true);
    }

    public static String dpLogical(Context c) {
        return sp(c).getString(K_DP_LOGICAL, DEF_DP_LOGICAL);
    }

    /**
     * The switches commit on their own, like :autodim does: a text field needs an
     * explicit save because it can hold an invalid value, a switch never can.
     */
    public static void setEnabled(Context c, boolean v) {
        sp(c).edit().putBoolean(K_ENABLED, v).apply();
    }

    public static void setManageDp(Context c, boolean v) {
        sp(c).edit().putBoolean(K_MANAGE_DP, v).apply();
    }

    public static void save(Context c, String size, int density, String pattern, boolean enabled,
                     String dpMode, boolean manageDp, String dpLogical) {
        sp(c).edit()
                .putString(K_SIZE, size)
                .putInt(K_DENSITY, density)
                .putString(K_PATTERN, pattern)
                .putBoolean(K_ENABLED, enabled)
                .putString(K_DP_MODE, dpMode)
                .putBoolean(K_MANAGE_DP, manageDp)
                .putString(K_DP_LOGICAL, dpLogical)
                .apply();
    }
}
