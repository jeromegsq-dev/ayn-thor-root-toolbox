package com.jeromegsq.thortoolbox

import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import com.jeromegsq.thortoolbox.bridge.ToolboxBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The only activity: a Flutter surface plus the channels the three tools need.
 *
 * All three screens are Dart now; what stays on this side is the part that has
 * to be Android — the settings files the root script and the quick settings tile
 * also read, the display watch service, and the `su` shells.
 */
class MainActivity : FlutterActivity() {

    private var bridge: ToolboxBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android draws its own focus ring around whatever view holds focus the
        // moment it sees a D-pad or keyboard press instead of a touch — which is
        // exactly how the gamepad screens are driven. FlutterView is attached
        // without an AttributeSet, so the theme's own defaultFocusHighlightEnabled
        // item does not reliably reach it; turning it off on the view tree does.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            disableDefaultFocusHighlight(window.decorView)
        }
    }

    private fun disableDefaultFocusHighlight(view: View) {
        view.defaultFocusHighlightEnabled = false
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                disableDefaultFocusHighlight(view.getChildAt(i))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = ToolboxBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    // Both callbacks see the event before the widget tree does, which is what
    // the preview needs: the merged pad reaches a game the same way.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        bridge?.input?.onKeyEvent(event) == true || super.dispatchKeyEvent(event)

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        bridge?.input?.onMotionEvent(event) == true || super.dispatchGenericMotionEvent(event)

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.detach()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
