package com.jeromegsq.thortoolbox.aspect;

import android.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.concurrent.TimeUnit;

/**
 * Runs commands as root.
 *
 * `wm size` and `wm density` go through IWindowManager and need the shell or
 * WRITE_SECURE_SETTINGS, which an ordinary app cannot hold — hence `su`.
 */
public final class Root {

    public static final String TAG = "ThorAspect";

    private Root() {
    }

    /** Runs every command in a single root shell. Returns its output, or null on failure. */
    public static String run(String... commands) {
        Process p = null;
        try {
            // Plain `su` is enough here: nothing touches /data/adb, which on this
            // device is invisible from the inherited mount namespace and would
            // need `su -mm`.
            p = new ProcessBuilder("su").redirectErrorStream(true).start();

            OutputStreamWriter out = new OutputStreamWriter(p.getOutputStream());
            for (String cmd : commands) {
                out.write(cmd);
                out.write("\n");
            }
            out.write("exit\n");
            out.flush();

            StringBuilder sb = new StringBuilder();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }

            if (!p.waitFor(15, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                Log.w(TAG, "su: timed out");
                return null;
            }
            if (p.exitValue() != 0) {
                Log.w(TAG, "su: exit " + p.exitValue() + " / " + sb);
                return null;
            }
            return sb.toString();
        } catch (Exception e) {
            Log.w(TAG, "su unavailable", e);
            if (p != null) {
                p.destroyForcibly();
            }
            return null;
        }
    }
}
