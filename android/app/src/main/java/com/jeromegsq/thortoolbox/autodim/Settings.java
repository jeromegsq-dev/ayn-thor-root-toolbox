package com.jeromegsq.thortoolbox.autodim;

import android.content.Context;

import com.jeromegsq.thortoolbox.Props;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.List;

/**
 * Settings shared with the root script /data/adb/service.d/bottom-autodim.sh.
 *
 * They travel through a key=value file in the app's private directory: only the
 * app writes it, root can read it, so the app needs no superuser access at all.
 * The script re-reads it on every idle cycle.
 */
public final class Settings {

    /** Backlight scale of the bottom panel. */
    public static final int BRIGHTNESS_MAX = 4095;

    public static final int DEF_TIMEOUT = 5;
    public static final int DEF_MIN = 0;
    public static final int DEF_FADE = 800;

    /** Set by the script at startup, readable without root. */
    private static final String PROP_SERVICE = "autodim.service";

    /** Pre-app settings, inherited once on first launch. */
    private static final String PROP_PREFIX = "persist.autodim.";

    private static final String FILE = "config";

    private Settings() {
    }

    public static final class Config {
        public boolean enabled;
        public int timeout = DEF_TIMEOUT;
        public int min = DEF_MIN;
        public int fade = DEF_FADE;
    }

    /** Reads the file only: spawns nothing, so it is safe on the main thread. */
    public static Config load(Context c) {
        Config cfg = new Config();
        File f = new File(c.getFilesDir(), FILE);
        if (!f.exists()) {
            return cfg;
        }

        try {
            List<String> lines = Files.readAllLines(f.toPath(), StandardCharsets.UTF_8);
            for (String line : lines) {
                int eq = line.indexOf('=');
                if (eq <= 0) {
                    continue;
                }
                String key = line.substring(0, eq).trim();
                int value;
                try {
                    value = Integer.parseInt(line.substring(eq + 1).trim());
                } catch (NumberFormatException e) {
                    continue;
                }
                switch (key) {
                    case "enabled": cfg.enabled = value == 1; break;
                    case "timeout": cfg.timeout = value; break;
                    case "min": cfg.min = value; break;
                    case "fade": cfg.fade = value; break;
                    default: break;
                }
            }
        } catch (IOException e) {
            // Unreadable: fall back to defaults.
        }
        return cfg;
    }

    /**
     * Like {@link #load}, but seeds the file from the props on first launch so a
     * command line setup is not lost. Spawns processes and writes to disk: call
     * off the main thread.
     */
    public static Config loadOrSeed(Context c) {
        if (new File(c.getFilesDir(), FILE).exists()) {
            return load(c);
        }

        Config cfg = new Config();
        cfg.enabled = "1".equals(Props.get(PROP_PREFIX + "enabled"));
        cfg.timeout = Props.getInt(PROP_PREFIX + "timeout", DEF_TIMEOUT);
        cfg.min = Props.getInt(PROP_PREFIX + "min", DEF_MIN);
        cfg.fade = Props.getInt(PROP_PREFIX + "fade", DEF_FADE);
        // Commit it now: the file becomes the single source of truth and the
        // tile never has to read the props.
        save(c, cfg);
        return cfg;
    }

    /** Atomic write: the script must never read a half-written file. */
    public static boolean save(Context c, Config cfg) {
        String text = "enabled=" + (cfg.enabled ? 1 : 0) + "\n"
                + "timeout=" + cfg.timeout + "\n"
                + "min=" + cfg.min + "\n"
                + "fade=" + cfg.fade + "\n";

        File tmp = new File(c.getFilesDir(), FILE + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        } catch (IOException e) {
            return false;
        }
        return tmp.renameTo(new File(c.getFilesDir(), FILE));
    }

    public static boolean serviceRunning() {
        return "1".equals(Props.get(PROP_SERVICE));
    }
}
