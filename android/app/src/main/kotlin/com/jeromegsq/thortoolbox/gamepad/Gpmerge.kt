package com.jeromegsq.thortoolbox.gamepad

/**
 * The root half of the gamepad tool: everything that needs `su`.
 *
 * The daemon, its Magisk module and the `/vendor/etc/excluded-input-devices.xml`
 * overlay that hides the source pads all live outside the APK, under `gpmerge/`
 * in this repository.
 *
 * Nothing here interprets gpmerge.conf. Parsing it, rendering it back and naming
 * buttons and axes is plain logic with no platform in it, so it lives in Dart
 * (`lib/src/gamepad/profile.dart`) and this side only moves the text.
 */
object Gpmerge {
    const val BIN = "/data/adb/modules/gpmerge/gpmerge"
    const val CONF = "/data/adb/modules/gpmerge/gpmerge.conf"

    /** The daemon's own virtual pad — the one thing that must stay visible. */
    const val MERGED = "AYN Unified Gamepad"

    /**
     * Devices Android's EventHub skips, as the Magisk module overlays it onto
     * `/vendor/etc/`. Read at boot and only at boot, so a change here costs a
     * reboot — there is no runtime way to take an input device away from
     * Android.
     */
    private const val EXCLUDE =
        "/data/adb/modules/gpmerge/system/vendor/etc/excluded-input-devices.xml"

    /**
     * Stock AYN entries: haptics actuators, which are not input devices. They
     * were in the file before the module existed and dropping them would hand
     * Android two devices it has no business reading.
     */
    private val STOCK = listOf("qti-haptics", "qcom-hv-haptics")

    fun readExclusions(): List<String> {
        val text = RootShell.run("cat $EXCLUDE 2>/dev/null").out.joinToString("\n")
        return Regex("""name\s*=\s*"([^"]*)"""").findAll(text)
            .map { it.groupValues[1] }
            .toList()
    }

    /**
     * Rewrites the list, keeping [STOCK] whatever happens and never hiding the
     * merged pad: excluding that one would leave the device with no controller
     * at all, the sources being hidden already.
     */
    fun writeExclusions(names: List<String>): Boolean {
        val wanted = (STOCK + names).distinct().filter { it != MERGED }
        val body = wanted.joinToString("\n") { """    <device name="${escape(it)}"/>""" }
        val text = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<!-- Devices Android's EventHub must ignore.
            |
            |     Written by the AYN Thor Toolbox app. The first entries are the stock
            |     AYN Thor list (haptics actuators, not input devices); the rest are the
            |     controllers hidden so that only the single merged pad is seen, and every
            |     controller therefore acts as player 1.
            |
            |     Read at boot only: a change here needs a reboot. The AYN mapper
            |     (com.odin.mapping) still sees these devices normally, and so does
            |     gpmerge — this file only affects Android's own input reader. -->
            |<devices>
            |$body
            |</devices>
        """.trimMargin()

        val script = "mkdir -p ${'$'}(dirname $EXCLUDE)\n" +
            heredocTo(EXCLUDE, text) + "\n" +
            "chmod 644 $EXCLUDE\necho WROTE_OK"
        return RootShell.run(script).out.any { it.trim() == "WROTE_OK" }
    }

    /**
     * A `cat > path` heredoc whose delimiter is drawn fresh every call.
     *
     * The payloads written here are not fully ours: the profile file is
     * user-edited text, and the exclusion list embeds controller names, which
     * come from whatever the device advertises over USB or Bluetooth. A line in
     * either that matched a fixed delimiter would close the heredoc early and
     * leave the remainder to be read as commands — by a root shell. A random
     * delimiter cannot be guessed by something that never sees it.
     */
    private fun heredocTo(path: String, text: String): String {
        val eof = "GPM_EOF_" + java.util.UUID.randomUUID().toString().replace("-", "")
        return "cat > $path <<'$eof'\n$text\n$eof"
    }

    private fun escape(s: String) = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")

    fun hasRoot(): Boolean =
        RootShell.run("id -u", timeoutSec = 25).out.any { it.trim() == "0" }

    // Match the process name exactly. "pgrep -f" would also match the shell
    // running this very command, since its command line contains the path.
    fun daemonRunning(): Boolean =
        RootShell.run("pgrep -x gpmerge >/dev/null && echo yes").out.any { it.trim() == "yes" }

    /** Controllers the daemon is merging right now, as maps for the channel. */
    fun listPads(): List<Map<String, String>> =
        RootShell.run("$BIN --list").out
            .filter { it.startsWith("DEV\t") }
            .mapNotNull { line ->
                val f = line.split("\t")
                if (f.size >= 5) {
                    mapOf("name" to f[1], "vendor" to f[2], "product" to f[3], "node" to f[4])
                } else {
                    null
                }
            }

    fun readConfig(): String = RootShell.run("cat $CONF 2>/dev/null").out.joinToString("\n")

    /**
     * Write the config and ask the running daemon to reload it. SIGHUP re-reads
     * the profiles without dropping any controller, so nothing disconnects.
     */
    fun writeConfig(text: String): Boolean {
        val heredoc = heredocTo(CONF, text)
        // -x, not -f: with -f the shell running this script matches itself
        // (its command line embeds the path) and dies on the SIGHUP.
        val script = "$heredoc\nchmod 644 $CONF\npkill -HUP -x gpmerge\necho WROTE_OK"
        val r = RootShell.run(script)
        return r.out.any { it.trim() == "WROTE_OK" }
    }

    /**
     * Streams the daemon's event log line by line.
     *
     * `--watch` reports which physical pad each event came from, which the app
     * cannot know otherwise: by the time input reaches Android every controller
     * has already been merged into a single device. The stream is bounded with
     * `timeout` so the root process always goes away, even if the user never
     * touches the pad.
     */
    fun watch(seconds: Int, onLine: (String) -> Unit, onEnd: () -> Unit): Process? =
        RootShell.stream("timeout $seconds $BIN --watch", onLine, onEnd)
}
