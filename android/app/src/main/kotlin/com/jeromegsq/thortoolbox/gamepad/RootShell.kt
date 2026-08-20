package com.jeromegsq.thortoolbox.gamepad

import java.io.BufferedReader
import java.util.concurrent.TimeUnit

/**
 * A deliberately small root layer: one `su -c` process per command.
 *
 * This replaces libsu, which blocked indefinitely on this device without ever
 * throwing. Spawning a process per command is slightly less efficient than a
 * persistent root shell, but every call here is either instant or explicitly
 * bounded, and a hang is visible as a timeout rather than a frozen screen.
 *
 * Never call these from the main thread.
 */
object RootShell {

    data class Result(val code: Int, val out: List<String>, val err: List<String>) {
        val ok get() = code == 0
    }

    /**
     * Runs [cmd] as root, giving up after [timeoutSec] so the UI cannot freeze.
     *
     * [mm] asks for a mount namespace merged with the global one (`su -mm`).
     * Plain `su -c` is enough for most commands, but on at least one device
     * `/data/adb` is invisible from the inherited namespace without it.
     */
    fun run(cmd: String, timeoutSec: Long = 15, mm: Boolean = false): Result {
        val args = if (mm) arrayOf("su", "-mm", "-c", cmd) else arrayOf("su", "-c", cmd)
        val p = try {
            ProcessBuilder(*args).start()
        } catch (e: Exception) {
            return Result(-1, emptyList(), listOf("cannot start su: ${e.message}"))
        }

        // Drain both pipes concurrently: a full stderr buffer would deadlock a
        // process whose stdout we are still reading.
        val out = mutableListOf<String>()
        val err = mutableListOf<String>()
        val tOut = drain(p.inputStream.bufferedReader(), out)
        val tErr = drain(p.errorStream.bufferedReader(), err)

        val finished = p.waitFor(timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            p.destroyForcibly()
            return Result(-2, out, err + "timed out after ${timeoutSec}s")
        }
        tOut.join(2000)
        tErr.join(2000)
        return Result(p.exitValue(), out, err)
    }

    private fun drain(reader: BufferedReader, into: MutableList<String>) =
        Thread {
            try {
                reader.forEachLine { synchronized(into) { into.add(it) } }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true; start() }

    /**
     * Runs [cmd] as root and delivers stdout line by line until the process
     * ends. The returned process lets the caller stop it early.
     */
    fun stream(cmd: String, onLine: (String) -> Unit, onEnd: () -> Unit): Process? {
        val p = try {
            ProcessBuilder("su", "-c", cmd).start()
        } catch (e: Exception) {
            onEnd()
            return null
        }
        Thread {
            try {
                p.inputStream.bufferedReader().forEachLine(onLine)
            } catch (_: Exception) {
            } finally {
                onEnd()
            }
        }.apply { isDaemon = true; start() }
        return p
    }
}
