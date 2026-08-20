package com.jeromegsq.thortoolbox;

import java.io.BufferedReader;
import java.io.InputStreamReader;

/**
 * System property reads through /system/bin/getprop. android.os.SystemProperties
 * is not public API, so this avoids reflecting on a hidden class.
 *
 * Reading needs no superuser access, which is why :aspect goes through here
 * rather than through its root shell for the props it only checks.
 */
public final class Props {

    private Props() {
    }

    /** Value, or null if the property is empty or unreadable. */
    public static String get(String name) {
        try {
            Process p = new ProcessBuilder("getprop", name).redirectErrorStream(true).start();
            String value = null;
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                // Drain fully before waiting: stopping at the first line could
                // leave the process blocked on a full pipe, and waitFor() hang.
                String line;
                while ((line = r.readLine()) != null) {
                    if (value == null) {
                        value = line;
                    }
                }
            }
            p.waitFor();
            if (value == null || value.trim().isEmpty()) {
                return null;
            }
            return value.trim();
        } catch (Exception e) {
            return null;
        }
    }

    public static int getInt(String name, int def) {
        String v = get(name);
        if (v == null) {
            return def;
        }
        try {
            return Integer.parseInt(v);
        } catch (NumberFormatException e) {
            return def;
        }
    }
}
