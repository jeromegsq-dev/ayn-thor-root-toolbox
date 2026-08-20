package com.jeromegsq.thortoolbox.nso

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.jeromegsq.thortoolbox.MainActivity
import com.jeromegsq.thortoolbox.R

/**
 * Home screen widget: one press to wake the NSO GameCube pad and connect it.
 *
 * Same action as the quick settings tile, on the other surface — this one works
 * on whatever launcher is in use, which the quick settings tile does not reach
 * from every screen.
 */
class NsoWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, manager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TAP) return
        NsoGamepad.get(context).toggle()
        // Straight away rather than only on the state that follows: a scan
        // takes seconds to say anything, and a widget that stays blank in the
        // meantime reads as a press that did not land.
        refresh(context)
    }

    companion object {
        private const val ACTION_TAP = "com.jeromegsq.thortoolbox.NSO_WIDGET_TAP"

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, NsoWidget::class.java))
            for (id in ids) render(context, manager, id)
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val status = NsoGamepad.get(context).status()
            val views = RemoteViews(context.packageName, R.layout.nso_widget)
            // Only the second line changes; the title is fixed in the layout.
            views.setTextViewText(R.id.nso_widget_status, context.getString(NsoTileService.subtitleOf(status)))
            views.setOnClickPendingIntent(R.id.nso_widget_root, tap(context))
            manager.updateAppWidget(id, views)
        }

        /**
         * What a press does, decided while drawing rather than when it lands:
         * a widget cannot ask for Bluetooth permission, and starting the app
         * from inside [onReceive] would be a background activity launch. With
         * the permission missing the press simply opens the app instead, whose
         * pad screen asks on the way in.
         */
        private fun tap(context: Context): PendingIntent {
            if (NsoGamepad.missingPermissions(context).isNotEmpty()) {
                return PendingIntent.getActivity(
                    context,
                    1,
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }
            return PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, NsoWidget::class.java).setAction(ACTION_TAP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
    }
}
