package com.jeromegsq.thortoolbox.nso

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.jeromegsq.thortoolbox.MainActivity
import com.jeromegsq.thortoolbox.R

/**
 * Quick settings tile: brings the NSO GameCube pad up, and puts it back down.
 *
 * The one surface that works without leaving whatever is on screen — which is
 * the case that matters, since a pad that idled out is noticed mid-game, and
 * the alternative is quitting to the launcher to press a button in an app.
 */
class NsoTileService : TileService() {

    override fun onStartListening() = render()

    override fun onClick() {
        // A tile is not an activity and cannot ask for anything: if Bluetooth
        // was never granted, the most it can do is open the app, whose pad
        // screen asks on the way in.
        if (NsoGamepad.missingPermissions(this).isNotEmpty()) {
            openApp()
            return
        }
        NsoGamepad.get(this).toggle()
        render()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // 34 refuses the Intent overload outright; only a PendingIntent
            // carries the right to start an activity from behind the shade.
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun render() {
        val tile = getQsTile() ?: return
        val status = NsoGamepad.get(this).status()
        tile.state = if (status == NsoGamepad.Status.CONNECTED) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.nso_tile_label)
        tile.subtitle = getString(subtitleOf(status))
        tile.icon = Icon.createWithResource(this, R.drawable.ic_nso_tile)
        tile.updateTile()
    }

    companion object {
        /** What each state reads as, shared with the widget so they never
         * disagree about the same pad. */
        fun subtitleOf(status: NsoGamepad.Status): Int = when (status) {
            NsoGamepad.Status.CONNECTED -> R.string.nso_state_connected
            NsoGamepad.Status.SCANNING -> R.string.nso_state_scanning
            NsoGamepad.Status.CONNECTING -> R.string.nso_state_connecting
            NsoGamepad.Status.OFF -> R.string.nso_state_off
        }

        /**
         * Asks the system to call [onStartListening] again, which is the only
         * way to redraw a tile nobody is currently looking at. A no-op when the
         * shade is closed, so it costs nothing to call on every state change.
         */
        fun refresh(context: Context) {
            requestListeningState(context, ComponentName(context, NsoTileService::class.java))
        }
    }
}
