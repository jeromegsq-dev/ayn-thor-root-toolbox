package com.jeromegsq.thortoolbox.bridge

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.input.InputManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import com.jeromegsq.thortoolbox.aspect.DisplayWatchService
import com.jeromegsq.thortoolbox.aspect.Root
import com.jeromegsq.thortoolbox.gamepad.GameProfileService
import com.jeromegsq.thortoolbox.gamepad.GameProfiles
import com.jeromegsq.thortoolbox.gamepad.Gpmerge
import com.jeromegsq.thortoolbox.gamepad.InstalledApps
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException
import com.jeromegsq.thortoolbox.aspect.Settings as AspectSettings
import com.jeromegsq.thortoolbox.autodim.Settings as AutoDimSettings

/**
 * Everything the Dart side cannot do itself, behind one method channel.
 *
 * The three tools keep the root models the README describes: AutoDim only writes
 * a settings file the Magisk service reads, the 4:3 tool calls `su` through its
 * watch service, and the gamepad screen shells out to the gpmerge daemon. This
 * class is a doorway, not a place to put logic — the split is the same as before,
 * it just runs behind a channel instead of behind a view.
 */
class ToolboxBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        private const val METHODS = "com.jeromegsq.thortoolbox/methods"
        private const val ASPECT_STATE = "com.jeromegsq.thortoolbox/aspect_state"
        private const val GAMEPAD_WATCH = "com.jeromegsq.thortoolbox/gamepad_watch"
        private const val GAMEPAD_INPUT = "com.jeromegsq.thortoolbox/gamepad_input"
        private const val NSO = "com.jeromegsq.thortoolbox/nso"
    }

    /** Fed by the activity's input callbacks, for the preview screen. */
    val input = GamepadInputChannel()

    // One thread, like the executors the sections used to own: root shells and
    // the settings file are both happier serialised.
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var methods: MethodChannel? = null
    private var aspectState: EventChannel? = null
    private var gamepadWatch: EventChannel? = null
    private var gamepadInput: EventChannel? = null
    private var nso: EventChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, METHODS).also { it.setMethodCallHandler(this) }
        aspectState = EventChannel(messenger, ASPECT_STATE).also {
            it.setStreamHandler(AspectStateChannel(activity))
        }
        gamepadWatch = EventChannel(messenger, GAMEPAD_WATCH).also {
            it.setStreamHandler(GamepadWatchChannel())
        }
        gamepadInput = EventChannel(messenger, GAMEPAD_INPUT).also {
            it.setStreamHandler(input)
        }
        nso = EventChannel(messenger, NSO).also {
            it.setStreamHandler(NsoChannel(activity))
        }
    }

    fun detach() {
        methods?.setMethodCallHandler(null)
        aspectState?.setStreamHandler(null)
        gamepadWatch?.setStreamHandler(null)
        gamepadInput?.setStreamHandler(null)
        nso?.setStreamHandler(null)
        methods = null
        aspectState = null
        gamepadWatch = null
        gamepadInput = null
        nso = null
        // shutdown(), not shutdownNow(): a queued settings write must still go
        // through.
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "autodim.load" -> async(result) {
                val cfg = AutoDimSettings.loadOrSeed(activity)
                mapOf(
                    "enabled" to cfg.enabled,
                    "timeout" to cfg.timeout,
                    "min" to cfg.min,
                    "fade" to cfg.fade,
                    "brightnessMax" to AutoDimSettings.BRIGHTNESS_MAX,
                    "serviceRunning" to AutoDimSettings.serviceRunning(),
                )
            }

            "autodim.save" -> {
                val cfg = AutoDimSettings.Config().apply {
                    enabled = call.argument<Boolean>("enabled") ?: false
                    timeout = call.argument<Int>("timeout") ?: AutoDimSettings.DEF_TIMEOUT
                    min = call.argument<Int>("min") ?: AutoDimSettings.DEF_MIN
                    fade = call.argument<Int>("fade") ?: AutoDimSettings.DEF_FADE
                }
                async(result) { AutoDimSettings.save(activity, cfg) }
            }

            // Installs and starts the Magisk service in one tap, for whoever
            // sees "service not found" and has no adb handy.
            "autodim.install" -> async(result) { com.jeromegsq.thortoolbox.autodim.Installer.install(activity) }

            "aspect.load" -> async(result) {
                mapOf(
                    "enabled" to AspectSettings.enabled(activity),
                    "size" to AspectSettings.size(activity),
                    "density" to AspectSettings.density(activity),
                    "pattern" to AspectSettings.pattern(activity),
                    "manageDp" to AspectSettings.manageDp(activity),
                    "dpMode" to AspectSettings.dpMode(activity),
                    "dpLogical" to AspectSettings.dpLogical(activity),
                )
            }

            "aspect.save" -> async(result) {
                AspectSettings.save(
                    activity,
                    call.argument<String>("size")!!,
                    call.argument<Int>("density")!!,
                    call.argument<String>("pattern")!!,
                    call.argument<Boolean>("enabled")!!,
                    call.argument<String>("dpMode")!!,
                    call.argument<Boolean>("manageDp")!!,
                    call.argument<String>("dpLogical")!!,
                )
                // Makes the service re-evaluate straight away with the new settings.
                DisplayWatchService.start(activity)
                true
            }

            "aspect.setEnabled" -> {
                val on = call.arguments as Boolean
                AspectSettings.setEnabled(activity, on)
                if (on) {
                    requestNotifications()
                }
                // Started either way: switched off, the service resets the screen
                // and then stops itself.
                DisplayWatchService.start(activity)
                result.success(null)
            }

            "aspect.setManageDp" -> {
                AspectSettings.setManageDp(activity, call.arguments as Boolean)
                if (AspectSettings.enabled(activity)) {
                    DisplayWatchService.start(activity)
                }
                result.success(null)
            }

            // Opening another screen must not pull in superuser access: the watch
            // service only comes up when this tool is switched on.
            "aspect.sync" -> {
                if (AspectSettings.enabled(activity)) {
                    requestNotifications()
                    DisplayWatchService.start(activity)
                }
                result.success(null)
            }

            // Checked here rather than in Dart on purpose: the pattern is fed to
            // java.util.regex, whose syntax is not the one Dart implements. The
            // default `(?i)…` is a plain FormatException on that side, so a Dart
            // check would reject a pattern the watch service is perfectly happy
            // with. Whoever ends up compiling it is who gets to judge it.
            "aspect.checkPattern" -> {
                val ok = try {
                    Pattern.compile(call.arguments as String)
                    true
                } catch (e: PatternSyntaxException) {
                    false
                }
                result.success(ok)
            }

            "aspect.resetNow" -> async(result) {
                Root.run("wm size reset", "wm density reset") != null
            }

            "aspect.displays" -> result.success(displays())

            "gamepad.state" -> {
                // Read on the main thread, before the root work: this is the
                // one part of the screen that needs no superuser access, and it
                // is what says whether a game would count several controllers.
                val seen = androidPads()
                async(result) {
                    val rooted = Gpmerge.hasRoot()
                    mapOf(
                        "rooted" to rooted,
                        "running" to if (rooted) Gpmerge.daemonRunning() else false,
                        "pads" to if (rooted) Gpmerge.listPads() else emptyList(),
                        "config" to if (rooted) Gpmerge.readConfig() else "",
                        "androidPads" to seen,
                        "excluded" to if (rooted) Gpmerge.readExclusions() else emptyList(),
                        "merged" to Gpmerge.MERGED,
                    )
                }
            }

            "gamepad.setExclusions" -> {
                @Suppress("UNCHECKED_CAST")
                val names = call.arguments as List<String>
                async(result) { Gpmerge.writeExclusions(names) }
            }

            "gamepad.writeConfig" -> {
                val text = call.arguments as String
                async(result) { Gpmerge.writeConfig(text) }
            }

            // ---- Per-game gamepad profiles -------------------------------

            "apps.list" -> async(result) { InstalledApps.list(activity) }

            "gameprofiles.load" -> result.success(
                mapOf(
                    "enabled" to GameProfiles.enabled(activity),
                    "games" to GameProfiles.games(activity).map {
                        mapOf("package" to it.pkg, "label" to it.label, "config" to it.config)
                    },
                ),
            )

            "gameprofiles.setEnabled" -> {
                val on = call.arguments as Boolean
                GameProfiles.setEnabled(activity, on)
                if (on) GameProfileService.start(activity) else GameProfileService.stop(activity)
                result.success(null)
            }

            "gameprofiles.addGame" -> {
                val pkg = call.argument<String>("package")!!
                val label = call.argument<String>("label")!!
                GameProfiles.addGame(activity, pkg, label)
                result.success(true)
            }

            "gameprofiles.removeGame" -> {
                GameProfiles.removeGame(activity, call.arguments as String)
                result.success(true)
            }

            "gameprofiles.saveGame" -> {
                val pkg = call.argument<String>("package")!!
                val config = call.argument<String>("config")!!
                GameProfiles.saveGame(activity, pkg, config)
                result.success(true)
            }

            // Ends the pad session outright. Closing the screen only detaches
            // from it, since the pad is meant to keep working without it.
            "nso.disconnect" -> {
                com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).disconnect()
                result.success(null)
            }

            // The pad remembered from a previous session, for a one-tap
            // reconnect that skips the scan entirely.
            "nso.known" -> result.success(com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).knownPad())

            // Rumble strength, 0..100, persisted independently of any active
            // session — a preference, not something tied to being connected.
            "nso.rumbleStrength" -> result.success(com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).rumbleStrength)

            // Scan, pick the pad out of what answers, connect — the whole
            // bring-up behind one call, so it can be started from a launcher
            // tile as well as from the diagnostic screen. False means the
            // Bluetooth permissions were missing and have just been asked for.
            "nso.autoConnect" -> {
                val missing = com.jeromegsq.thortoolbox.nso.NsoGamepad.missingPermissions(activity)
                if (missing.isNotEmpty()) {
                    activity.requestPermissions(missing.toTypedArray(), 2)
                    result.success(false)
                } else {
                    com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).autoConnect()
                    result.success(true)
                }
            }

            // Says "you are player one" again, for a pad that kept running its
            // own lamp animation through the bring-up.
            "nso.playerLed" -> {
                com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).setPlayerLed()
                result.success(null)
            }

            "nso.setRumbleStrength" -> {
                com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).rumbleStrength = call.arguments as Int
                result.success(null)
            }

            // One tap, no game and no gpmerge merge needed to answer "does the
            // motor still work".
            "nso.testRumble" -> {
                com.jeromegsq.thortoolbox.nso.NsoGamepad.get(activity).testRumble()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Runs [work] off the main thread and answers the channel back on it. */
    private fun async(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            // Surface failures instead of leaving the screen waiting: anything
            // thrown here would otherwise die with the thread.
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (t: Throwable) {
                val message = "${t.javaClass.simpleName}: ${t.message}"
                main.post { result.error("failed", message, null) }
            }
        }
    }

    /**
     * The controllers Android hands to apps — which is what a game enumerates.
     * Anything here besides the merged pad is a second player as far as a game
     * is concerned, however quiet it is.
     */
    private fun androidPads(): List<Map<String, Any>> {
        val im = activity.getSystemService(InputManager::class.java)
        // toList(): the ids come back as an IntArray, which has no mapNotNull.
        return im.inputDeviceIds.toList().mapNotNull { id ->
            val device = InputDevice.getDevice(id) ?: return@mapNotNull null
            val sources = device.sources
            val pad = sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
                sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
            if (!pad || device.isVirtual) {
                null
            } else {
                mapOf("id" to id, "name" to (device.name ?: ""))
            }
        }
    }

    /** The displays the app can see, to help tune the name pattern. */
    private fun displays(): List<Map<String, Any>> {
        val dm = activity.getSystemService(DisplayManager::class.java)
        return dm.displays.map { d ->
            @Suppress("DEPRECATION")
            val size = Point().also { d.getRealSize(it) }
            mapOf(
                "id" to d.displayId,
                "name" to (d.name ?: ""),
                "width" to size.x,
                "height" to size.y,
            )
        }
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}
