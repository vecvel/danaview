// OWNER: AND-15
//
// Manual checklist helper (BUILD_PLAN AND-15, repeated in QA-02): a cross-app drag from Files on a
// tablet. Not part of a normal connected run: it is skipped unless `-e danaviewManualDrop true` is
// passed. It shows a FlutterView in androidx.test's EmptyActivity with the drop target enabled
// through the plugin's ActivityHost, then waits up to `danaviewManualDropSeconds` (default 120)
// for a person (or `adb shell input draganddrop`) to drag a file from the Files app onto it, with
// both apps in split screen (Overview > Split). Entering split screen resizes and recreates the
// activity; like the plugin (onReattachedToActivityForConfigChanges), the test then rebuilds the
// FlutterView and re-attaches the host, and DropTarget moves its listener to the new view on resume.
// It logs only counts, extensions and the logical position under DanaviewDropManual, and asserts
// that the dropped items were copied into work/drops/ (a cross-app content:// URI is readable only
// while the drag permissions are held).

package com.vecvel.danaview.editor.engine.drop

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.DropMsg
import com.vecvel.danaview.editor.engine.platform.DropTarget
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CrossAppDropManualTest {
    @Test
    fun dragFromFilesOntoTheEditorView() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("manual: run with -e danaviewManualDrop true", args.getString("danaviewManualDrop") == "true")
        val seconds = args.getString("danaviewManualDropSeconds")?.toLongOrNull() ?: 120L
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext
        val ctx = EngineContext(app, EngineThreads.android())
        ctx.installRoots(Paths.fromDart(File(app.cacheDir, "danaview/editor").absolutePath, File(app.filesDir, "danaview/editor").absolutePath))
        val intent = Intent(Intent.ACTION_MAIN)
            .setClassName(app.packageName, EMPTY_ACTIVITY)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target = DropTarget(ctx)
        val latch = CountDownLatch(1)
        var dropped: DropMsg? = null
        target.onDropHandled = {
            dropped = it
            if (it != null) latch.countDown()
        }
        var current: Activity? = null
        fun install(activity: Activity) {
            if (current === activity) return
            current = activity
            activity.findViewById<ViewGroup>(android.R.id.content).addView(
                FlutterView(activity),
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
            )
            ctx.activityHost.attach(Binding(activity))
        }
        val recreation = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (activity.javaClass.name == EMPTY_ACTIVITY && current != null) install(activity)
            }

            override fun onActivityDestroyed(activity: Activity) {
                if (activity === current && activity.isChangingConfigurations) ctx.activityHost.detach(cancelPending = false)
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        }
        val application = app as Application
        application.registerActivityLifecycleCallbacks(recreation)
        val first = instrumentation.startActivitySync(intent)
        instrumentation.runOnMainSync {
            install(first)
            target.setEnabled(true) {}
        }
        Log.i(TAG, "drop target ready for $seconds s")
        try {
            assertTrue("no drop within $seconds s", latch.await(seconds, TimeUnit.SECONDS))
            val msg = dropped!!
            val families = msg.items.map { it.displayName.substringAfterLast('.', "?").lowercase() }
            Log.i(TAG, "cross-app drop: ${msg.items.size} item(s) copied, extensions=$families, x=${msg.x} y=${msg.y} (logical px)")
            val root = ctx.requirePaths().workDrops.canonicalPath
            msg.items.forEach { assertTrue(File(it.uri).canonicalPath.startsWith("$root/") && File(it.uri).length() > 0) }
        } finally {
            application.unregisterActivityLifecycleCallbacks(recreation)
            instrumentation.runOnMainSync {
                target.setEnabled(false) {}
                ctx.activityHost.detach()
                current?.finish()
            }
            ctx.threads.shutdown()
        }
    }

    private class Binding(private val activity: Activity) : ActivityPluginBinding {
        override fun getActivity() = activity
        override fun getLifecycle(): Any = Any()
        override fun addRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) = Unit
        override fun removeRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) = Unit
        override fun addActivityResultListener(listener: PluginRegistry.ActivityResultListener) = Unit
        override fun removeActivityResultListener(listener: PluginRegistry.ActivityResultListener) = Unit
        override fun addOnNewIntentListener(listener: PluginRegistry.NewIntentListener) = Unit
        override fun removeOnNewIntentListener(listener: PluginRegistry.NewIntentListener) = Unit
        override fun addOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) = Unit
        override fun removeOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) = Unit
        override fun addOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) = Unit
        override fun removeOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) = Unit
        override fun addOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) = Unit
        override fun removeOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) = Unit
    }

    companion object {
        private const val TAG = "DanaviewDropManual"
        private const val EMPTY_ACTIVITY = "androidx.test.core.app.InstrumentationActivityInvoker\$EmptyActivity"
    }
}
