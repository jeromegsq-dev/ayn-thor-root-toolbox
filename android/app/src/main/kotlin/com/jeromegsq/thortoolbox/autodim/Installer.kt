package com.jeromegsq.thortoolbox.autodim

import android.content.Context
import com.jeromegsq.thortoolbox.gamepad.RootShell
import java.io.File

/**
 * Puts /data/adb/service.d/bottom-autodim.sh in place and starts it, without
 * adb or a reboot — the in-app answer to the README's manual install steps.
 *
 * The script backgrounds itself and loops forever once started, so running it
 * once now is exactly as good as it being picked up by Magisk at the next
 * boot. It ships as a bundled asset (see build.gradle.kts) rather than a copy
 * kept in this file, so there is only ever one version of it.
 */
object Installer {

    private const val ASSET = "bottom-autodim.sh"
    private const val TARGET = "/data/adb/service.d/bottom-autodim.sh"

    /**
     * Copies the script into place as root, marks it executable, and starts
     * it detached with `nohup` so it survives this call returning. `/data/adb`
     * needs `su -mm` to be visible at all on at least one device — see
     * [RootShell.run].
     */
    fun install(context: Context): Boolean {
        val staging = File(context.filesDir, ASSET)
        context.assets.open(ASSET).use { input -> staging.outputStream().use { input.copyTo(it) } }

        val src = staging.absolutePath
        val cmd = "cp '$src' '$TARGET' && chmod 755 '$TARGET' && (nohup sh '$TARGET' >/dev/null 2>&1 &)"
        if (!RootShell.run(cmd, timeoutSec = 10, mm = true).ok) return false

        // The script sets this prop moments after it starts; give it a little
        // room instead of reporting a working install as a failure.
        repeat(20) {
            if (Settings.serviceRunning()) return true
            Thread.sleep(150)
        }
        return Settings.serviceRunning()
    }
}
