package com.vecvel.danaview

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.android.FlutterView
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.JUnit4

/**
 * FIX-QA02-POLISH-1: after a hardware key press Android (API 26+) drew its default focus
 * highlight, a ~3 px frame, around the whole app window. The API 26+ themes turn it off;
 * Flutter keeps drawing its own keyboard-only focus rings inside the app.
 */
@RunWith(JUnit4::class)
class FocusHighlightTest {

    private fun findFlutterView(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    @Test
    fun noSystemFocusFrameAfterKeyPress() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.setInTouchMode(true)
        val intent = Intent(Intent.ACTION_MAIN)
            .setClassName(instrumentation.targetContext, MainActivity::class.java.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val activity = instrumentation.startActivitySync(intent) as MainActivity
        try {
            // The Flutter engine needs a moment for its first frames (debug build, JIT).
            SystemClock.sleep(8000)
            instrumentation.waitForIdleSync()

            // 1. The theme item reaches the views. Read on the main thread, assert here.
            val bounds = IntArray(4)
            var foundFlutterView = false
            var flutterViewHighlight = true
            var decorHighlight = true
            instrumentation.runOnMainSync {
                val decor = activity.window.decorView
                val flutterView = findFlutterView(decor)
                foundFlutterView = flutterView != null
                flutterViewHighlight = flutterView?.defaultFocusHighlightEnabled ?: true
                decorHighlight = decor.defaultFocusHighlightEnabled
                // The frame was drawn around the whole window (status bar included): check the
                // decor view's edges.
                val loc = IntArray(2)
                decor.getLocationOnScreen(loc)
                bounds[0] = loc[0]
                bounds[1] = loc[1]
                bounds[2] = decor.width
                bounds[3] = decor.height
            }
            assertTrue("no FlutterView in the window", foundFlutterView)
            assertFalse("FlutterView still has the system default focus highlight", flutterViewHighlight)
            assertFalse("decor view still has the system default focus highlight", decorHighlight)

            // 2. No frame appears along the window edges after a key press (pixel check).
            val before = instrumentation.uiAutomation.takeScreenshot()
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_DPAD_DOWN)
            SystemClock.sleep(1500)
            instrumentation.waitForIdleSync()
            val after = instrumentation.uiAutomation.takeScreenshot()
            val changed = changedEdgeFraction(before, after, bounds)
            assertTrue(
                "window edge changed after a key press (${"%.2f".format(changed)} of edge pixels): " +
                    "system focus frame is back",
                changed < 0.5,
            )
        } finally {
            activity.finish()
        }
    }

    /**
     * Fraction of pixels in the outer 3 px of the left and right edges of the window (middle 80 %
     * of its height, clear of the system bars) that changed between the two screenshots.
     */
    private fun changedEdgeFraction(before: Bitmap, after: Bitmap, b: IntArray): Double {
        val left = b[0].coerceIn(0, before.width - 1)
        val right = (b[0] + b[2] - 1).coerceIn(0, before.width - 1)
        val top = b[1] + b[3] / 10
        val bottom = (b[1] + b[3] * 9 / 10).coerceAtMost(before.height - 1)
        var total = 0
        var changed = 0
        for (y in top..bottom step 4) {
            for (dx in 0 until 3) {
                for (x in intArrayOf(left + dx, right - dx)) {
                    total++
                    val p = before.getPixel(x, y)
                    val q = after.getPixel(x, y)
                    val d = maxOf(
                        Math.abs(Color.red(p) - Color.red(q)),
                        Math.abs(Color.green(p) - Color.green(q)),
                        Math.abs(Color.blue(p) - Color.blue(q)),
                    )
                    if (d > 40) changed++
                }
            }
        }
        return if (total == 0) 0.0 else changed.toDouble() / total
    }
}
