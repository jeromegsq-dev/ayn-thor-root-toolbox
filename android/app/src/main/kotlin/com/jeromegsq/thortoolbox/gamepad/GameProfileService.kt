package com.jeromegsq.thortoolbox.gamepad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.widget.Toast
import com.jeromegsq.thortoolbox.MainActivity

/**
 * Switches the live gpmerge profile to whichever game is in front, so a remap
 * can be tuned per game instead of per physical pad only.
 *
 * The daemon has no window-manager visibility — it only reads /dev/input —
 * so this has to run on the Android side: poll root for the foreground
 * package, and when it belongs to a configured game, rewrite gpmerge.conf and
 * SIGHUP, the same reload path the profile editor already uses. Runs whether
 * or not the app itself is open, which is the whole point: the switch has to
 * survive leaving the toolbox for the game.
 */
class GameProfileService : Service() {

    companion object {
        private const val CHANNEL = "gameprofiles"
        private const val NOTIF_ID = 3
        private const val MARKER = "---thortoolbox-gp-tick---"
        private val SCRIPT =
            "while true; do dumpsys activity activities | grep topResumedActivity; echo $MARKER; sleep 2; done"

        fun start(c: Context) {
            c.startForegroundService(Intent(c, GameProfileService::class.java))
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, GameProfileService::class.java))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var proc: Process? = null
    private var screenOff = false
    private var stopped = false
    private var screenReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        enterForeground()

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        screenOff = true
                        proc?.destroyForcibly()
                        proc = null
                    }
                    Intent.ACTION_SCREEN_ON -> {
                        screenOff = false
                        startPolling()
                    }
                }
            }
        }
        screenReceiver = receiver
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }

        startPolling()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!GameProfiles.enabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopped = true
        proc?.destroyForcibly()
        proc = null
        screenReceiver?.let { unregisterReceiver(it) }
        screenReceiver = null
        super.onDestroy()
    }

    private fun startPolling() {
        if (stopped || proc != null) return
        val buffer = mutableListOf<String>()
        proc = RootShell.stream(
            SCRIPT,
            onLine = { line ->
                if (line == MARKER) {
                    val pkgs = buffer.mapNotNull(::packageOf)
                    buffer.clear()
                    if (pkgs.isNotEmpty()) main.post { onForeground(pkgs) }
                } else {
                    buffer.add(line)
                }
            },
            onEnd = {
                proc = null
                if (!stopped && !screenOff) main.postDelayed({ startPolling() }, 2000)
            },
        )
    }

    /**
     * [pkgs] is one package per display's `topResumedActivity`. Any of them
     * matching a configured game wins, regardless of which display it is on —
     * this device ships with more than one, and which one runs the game is
     * not this service's business to assume.
     */
    private fun onForeground(pkgs: List<String>) {
        val games = GameProfiles.games(this)
        val target = games.map { it.pkg }.firstOrNull { it in pkgs }
        val current = GameProfiles.currentTarget(this)
        if (target == current) return

        if (current == null) {
            // Leaving the default profile: capture it fresh, so coming back
            // later restores whatever was actually live, edits included.
            GameProfiles.setDefaultSnapshot(this, profilesOnly(Gpmerge.readConfig()))
        }

        val body = if (target == null) {
            // Nothing was ever captured yet, e.g. the very first switch after
            // enabling this while already on a matching game: leave the live
            // file alone rather than overwrite it with nothing.
            val snapshot = GameProfiles.defaultSnapshot(this)
            if (snapshot == null) {
                toast("Gamepad profiles: no default captured yet, left as is")
                return
            }
            snapshot
        } else {
            games.first { it.pkg == target }.config
        }

        val tail = shortcutsTail(Gpmerge.readConfig())
        val text = if (tail.isEmpty()) body.trimEnd() else "${body.trimEnd()}\n\n$tail"
        if (Gpmerge.writeConfig(text)) {
            GameProfiles.setCurrentTarget(this, target)
            toast(
                if (target == null) {
                    "Gamepad profile: back to default"
                } else {
                    "Gamepad profile: ${games.first { it.pkg == target }.label}"
                },
            )
        } else {
            toast("Gamepad profile: could not write gpmerge.conf (root denied?)")
        }
    }

    private fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
    }

    private fun packageOf(line: String): String? = Regex("""(\S+)/\S+""").find(line.trim())?.groupValues?.get(1)

    private val shortcutsHeader = Regex("(?im)^\\[\\s*shortcuts\\s*]\\s*$")

    /** Everything from the `[shortcuts]` header onward, kept untouched across every switch. */
    private fun shortcutsTail(conf: String): String {
        val idx = shortcutsHeader.find(conf)?.range?.first ?: return ""
        return conf.substring(idx)
    }

    private fun profilesOnly(conf: String): String {
        val idx = shortcutsHeader.find(conf)?.range?.first ?: return conf
        return conf.substring(0, idx)
    }

    private fun enterForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(CHANNEL, "Per-game gamepad profiles", NotificationManager.IMPORTANCE_LOW)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)

        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val notif = Notification.Builder(this, CHANNEL)
            .setContentTitle("Gamepad profiles")
            .setContentText("Watching for the active game")
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
