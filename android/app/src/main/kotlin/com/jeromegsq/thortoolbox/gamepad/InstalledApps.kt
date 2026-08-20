package com.jeromegsq.thortoolbox.gamepad

import android.content.Context
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Process
import java.io.ByteArrayOutputStream

/**
 * Installed apps, for the "add a game" picker in per-game gamepad profiles.
 *
 * `LauncherApps` rather than `queryIntentActivities`: it is the API meant for
 * exactly this, listing what a home screen would show, and it already answers
 * per profile. It still respects package visibility like anything else,
 * though — the `MAIN`/`LAUNCHER` entry in the manifest's `<queries>` is what
 * actually widens it past the handful of packages every app can see by
 * default; without that this comes back nearly empty. Icons come back as PNG
 * bytes rather than a path — an adaptive icon is two layers and a mask that
 * only the platform knows how to flatten.
 */
object InstalledApps {

    private const val ICON_PX = 96

    fun list(context: Context): List<Map<String, Any?>> {
        val launcher = context.getSystemService(LauncherApps::class.java)
        return launcher.getActivityList(null, Process.myUserHandle())
            .map { info ->
                mapOf(
                    "package" to info.applicationInfo.packageName,
                    "label" to info.label.toString(),
                    "icon" to png(info.getIcon(0)),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    private fun png(drawable: Drawable): ByteArray {
        // A plain bitmap drawable is already the picture; only the layered kinds
        // need a canvas to be flattened.
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, ICON_PX, ICON_PX, true)
        } else {
            Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888).also {
                drawable.setBounds(0, 0, ICON_PX, ICON_PX)
                drawable.draw(Canvas(it))
            }
        }
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    }
}
