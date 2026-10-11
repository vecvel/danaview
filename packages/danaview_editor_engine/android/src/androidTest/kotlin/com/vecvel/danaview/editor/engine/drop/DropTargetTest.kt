// OWNER: AND-15
//
// External drop target on the emulator (BUILD_PLAN AND-15, D-18). A FlutterView (no engine attached)
// sits in androidx.test's EmptyActivity, which the plugin's ActivityHost sees through a test
// ActivityPluginBinding. Synthesized DragEvents (DragEvents.kt) with ClipData of content:// URIs from
// a test content provider (the engine's FileProvider over test files: a video, an audio file, an
// image, a .cube LUT and an unsupported .txt; the library test APK has no manifest of its own to
// declare another provider) are dispatched to the view: STARTED/ENTERED are accepted only for
// supported MIME types; DROP yields one `drop` event with copies in work/drops/ (bytes equal),
// origin drop, isTemporaryCopy, and the position in logical pixels; the drag permissions are taken
// and released after the copies; an unsupported-only drop sends nothing; disabling removes the
// listener and later drops are ignored.

package com.vecvel.danaview.editor.engine.drop

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.Intent
import android.view.DragEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.DropMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.PickOriginMsg
import com.vecvel.danaview.editor.engine.platform.DropTarget
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class DropTargetTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext
    private lateinit var ctx: EngineContext
    private lateinit var activity: Activity
    private lateinit var flutterView: FlutterView
    private lateinit var target: DropTarget
    private lateinit var src: File
    private val events = ArrayList<EngineEventMsg>()

    private class TestBinding(private val activity: Activity) : ActivityPluginBinding {
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

    @Before
    fun setUp() {
        ctx = EngineContext(app, EngineThreads.android())
        ctx.installRoots(Paths.fromDart(File(app.cacheDir, "danaview/editor").absolutePath, File(app.filesDir, "danaview/editor").absolutePath))
        ctx.events.attach { e -> synchronized(events) { events.add(e) } }
        src = File(ctx.requirePaths().work, "test-src/drop").apply {
            deleteRecursively()
            mkdirs()
        }
        File(ctx.requirePaths().workDrops.path).deleteRecursively()
        val intent = Intent(Intent.ACTION_MAIN)
            .setClassName(app.packageName, "androidx.test.core.app.InstrumentationActivityInvoker\$EmptyActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity = instrumentation.startActivitySync(intent)
        instrumentation.runOnMainSync {
            flutterView = FlutterView(activity)
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
            content.addView(flutterView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            ctx.activityHost.attach(TestBinding(activity))
        }
        target = DropTarget(ctx)
    }

    @After
    fun tearDown() {
        instrumentation.runOnMainSync {
            target.setEnabled(false) {}
            ctx.activityHost.detach()
            activity.finish()
        }
        ctx.threads.shutdown()
    }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun enable(on: Boolean) {
        val latch = CountDownLatch(1)
        val done: Completion<Unit> = { latch.countDown() }
        onMain { target.setEnabled(on, done) }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
    }

    private fun file(name: String, bytes: ByteArray) = File(src, name).apply { writeBytes(bytes) }

    private fun uri(f: File) = FileProvider.getUriForFile(app, ctx.fileProviderAuthority, f)

    private fun dispatch(event: DragEvent): Boolean {
        var r = false
        onMain { r = flutterView.dispatchDragEvent(event) }
        return r
    }

    /** Dispatches a DROP and waits for the target to finish (copies done, permissions released). */
    private fun drop(clip: ClipData, description: ClipDescription, x: Float, y: Float, binder: FakePermissionsBinder): Pair<Boolean, DropMsg?> {
        val latch = CountDownLatch(1)
        var handled: DropMsg? = null
        target.onDropHandled = {
            handled = it
            latch.countDown()
        }
        val accepted = dispatch(DragEvents.obtain(DragEvent.ACTION_DROP, x, y, description, clip, binder))
        assertTrue("drop handled", latch.await(20, TimeUnit.SECONDS))
        return accepted to handled
    }

    @Test
    fun dropCopiesSupportedItemsReleasesPermissionsAndReportsLogicalPosition() {
        val mp4 = file("clip.mp4", TestFixtures.open(FixtureTree.ENGINE, "media/frame_counter_720p24.mp4").use { it.readBytes() })
        val m4a = file("voice.m4a", TestFixtures.open(FixtureTree.ENGINE, "media/speech_10s.m4a").use { it.readBytes() })
        val png = file("still.png", TestFixtures.open(FixtureTree.ENGINE, "media/alpha.png").use { it.readBytes() })
        val cube = file("look.cube", "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".toByteArray())
        val txt = file("notes.txt", "hello".toByteArray())
        enable(true)
        assertSame("listener on the FlutterView", flutterView, target.attachedView)

        val mimes = arrayOf("video/mp4", "audio/mp4", "image/png", "application/octet-stream", "text/plain")
        val description = ClipDescription("files", mimes)
        assertTrue("started accepted", dispatch(DragEvents.obtain(DragEvent.ACTION_DRAG_STARTED, 0f, 0f, description, null)))
        // ViewGroup routes ENTERED/EXITED through hidden enter/exit dispatch from ViewRootImpl, so it
        // is delivered to the installed listener directly; STARTED and DROP go through dispatchDragEvent.
        var entered = false
        onMain { entered = target.listener.onDrag(flutterView, DragEvents.obtain(DragEvent.ACTION_DRAG_ENTERED, 10f, 10f, description, null)) }
        assertTrue("entered", entered)

        val clip = ClipData(description, ClipData.Item(uri(mp4))).apply {
            listOf(m4a, png, cube, txt).forEach { addItem(ClipData.Item(uri(it))) }
        }
        val binder = FakePermissionsBinder()
        val (accepted, msg) = drop(clip, description, 300f, 600f, binder)
        assertTrue(accepted)
        assertTrue("permissions taken", binder.took)
        assertTrue("permissions released after the copies", binder.released)
        assertTrue(binder.codes.indexOf(FakePermissionsBinder.TAKE) < binder.codes.lastIndexOf(FakePermissionsBinder.RELEASE))
        val drop = msg!!
        val density = activity.resources.displayMetrics.density
        assertEquals(300.0 / density, drop.x, 1e-3)
        assertEquals(600.0 / density, drop.y, 1e-3)
        assertEquals(listOf("clip.mp4", "voice.m4a", "still.png", "look.cube"), drop.items.map { it.displayName })
        val sources = listOf(mp4, m4a, png, cube)
        val dropsRoot = ctx.requirePaths().workDrops.canonicalPath
        drop.items.forEachIndexed { i, item ->
            assertEquals(PickOriginMsg.DROP, item.origin)
            assertTrue(item.isTemporaryCopy)
            val copy = File(item.uri)
            assertTrue("copy under work/drops", copy.canonicalPath.startsWith("$dropsRoot/"))
            assertArrayEquals("bytes of ${item.displayName}", sources[i].readBytes(), copy.readBytes())
            assertEquals(sources[i].length(), item.sizeBytes)
        }
        // The same drop reached Dart's event stream.
        val end = System.currentTimeMillis() + 5_000
        var delivered: EngineEventMsg? = null
        while (delivered == null && System.currentTimeMillis() < end) {
            delivered = synchronized(events) { events.firstOrNull { it.kind == EngineEventKindMsg.DROP } }
            if (delivered == null) Thread.sleep(20)
        }
        assertEquals(drop, delivered!!.drop)
        dispatch(DragEvents.obtain(DragEvent.ACTION_DRAG_ENDED, 0f, 0f, description, null, result = true))
    }

    @Test
    fun unsupportedTypesAreRefusedAndSendNothing() {
        val txt = file("notes.txt", "hello".toByteArray())
        enable(true)
        val pdf = ClipDescription("doc", arrayOf("application/pdf"))
        assertFalse("pdf refused at drag start", dispatch(DragEvents.obtain(DragEvent.ACTION_DRAG_STARTED, 0f, 0f, pdf, null)))
        val textDescription = ClipDescription("notes", arrayOf("text/plain"))
        // text/plain may carry a .cube, so the drag itself is accepted; the item is refused on drop.
        assertTrue(dispatch(DragEvents.obtain(DragEvent.ACTION_DRAG_STARTED, 0f, 0f, textDescription, null)))
        val binder = FakePermissionsBinder()
        val (_, msg) = drop(ClipData(textDescription, ClipData.Item(uri(txt))), textDescription, 5f, 5f, binder)
        assertNull("nothing usable", msg)
        assertTrue(binder.released)
        Thread.sleep(200)
        assertTrue(synchronized(events) { events.none { it.kind == EngineEventKindMsg.DROP } })
        assertTrue(ctx.requirePaths().workDrops.listFiles().isNullOrEmpty())
    }

    @Test
    fun disableRemovesTheListener() {
        val mp4 = file("clip.mp4", ByteArray(1000) { it.toByte() })
        enable(true)
        assertTrue(target.isEnabled)
        enable(false)
        assertFalse(target.isEnabled)
        assertNull(target.attachedView)
        val description = ClipDescription("files", arrayOf("video/mp4"))
        assertFalse(dispatch(DragEvents.obtain(DragEvent.ACTION_DRAG_STARTED, 0f, 0f, description, null)))
        val clip = ClipData(description, ClipData.Item(uri(mp4)))
        assertFalse(dispatch(DragEvents.obtain(DragEvent.ACTION_DROP, 1f, 1f, description, clip, FakePermissionsBinder())))
        Thread.sleep(300)
        assertTrue(synchronized(events) { events.none { it.kind == EngineEventKindMsg.DROP } })
        // Enabling again attaches to the same view.
        enable(true)
        assertSame(flutterView, target.attachedView)
    }

    @Test
    fun acceptanceRules() {
        assertTrue(DropTarget.acceptable("video/quicktime", "a.mov", null))
        assertTrue(DropTarget.acceptable(null, "a.m4a", null))
        assertTrue(DropTarget.acceptable("application/octet-stream", "Teal.CUBE", null))
        assertFalse(DropTarget.acceptable("text/plain", "a.txt", null))
        assertFalse(DropTarget.acceptable("application/pdf", "a.pdf", null))
        assertEquals("a_b.mp4", DropTarget.sanitize("a/b.mp4"))
        assertEquals("hidden", DropTarget.sanitize(".hidden"))
        assertEquals(120, DropTarget.sanitize("x".repeat(300) + ".mp4").length)
        assertTrue(DropTarget.sanitize("x".repeat(300) + ".mp4").endsWith(".mp4"))
    }
}
