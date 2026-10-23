// OWNER: HOM-21A
//
// Instrumented tests of Android incoming intents (BUILD_PLAN HOM-21A) with real Intents, a real
// content provider (the pickers' RecordingProvider) and the plugin's IncomingHostApiImpl behind a
// fake ActivityPluginBinding:
// - snapshots of VIEW / SEND / SEND_MULTIPLE (EXTRA_STREAM as Uri, String or list; ClipData only;
//   EXTRA_TEXT; flags) and of malformed intents (wrong extra types) never throw;
// - claimed intents are marked handled (MainActivity's 1.1 handler skips them); video intents are
//   left exactly as they came;
// - items are described (names, MIME types, sizes; clashes numbered) without opening the source;
//   a text share becomes a file; file:// into the app's private storage is refused;
// - the host API: a cold-start intent is delivered once through takePending, a warm intent through
//   the new-intent listener, a re-created Activity (saved state) or a Recents relaunch is not
//   delivered again, acknowledge releases the batch (its text file goes away).

package com.vecvel.danaview.library.incoming

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.library.glue.LibraryEventHub
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pickers.RecordingProvider
import com.vecvel.danaview.library.pigeon.IncomingActionMsg
import com.vecvel.danaview.library.pigeon.IncomingBatchMsg
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.PluginRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer

@RunWith(AndroidJUnit4::class)
class IncomingIntentsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private lateinit var intents: IncomingIntents

    @Before
    fun setUp() {
        intents = IncomingIntents(context)
        RecordingProvider.modes.clear()
        File(RecordingProvider.dir(context), "Report.pdf").writeBytes(ByteArray(2048) { it.toByte() })
        File(RecordingProvider.dir(context), "Photo.jpg").writeBytes(ByteArray(777) { 7 })
        File(RecordingProvider.dir(context), "Clip.mp4").writeBytes(ByteArray(99))
        File(context.filesDir, "secret.db").writeText("private")
    }

    @After
    fun tearDown() {
        RecordingProvider.dir(context).deleteRecursively()
        File(context.filesDir, "secret.db").delete()
        intents.textRoot.deleteRecursively()
    }

    private fun rec(name: String) = RecordingProvider.uri(context, name)

    // ---------------------------------------------------------------------------------------------
    // Snapshots and routing

    @Test
    fun snapshotsOfRealIntents() {
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(rec("Report.pdf"), "application/pdf")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        IncomingIntents.snapshot(view).let {
            assertEquals(Intent.ACTION_VIEW, it.action)
            assertEquals("application/pdf", it.type)
            assertEquals(rec("Report.pdf").toString(), it.data)
            assertTrue(it.persistableGrant)
            assertFalse(it.fromHistory)
        }

        val send = Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, rec("Photo.jpg"))
        assertEquals(listOf(rec("Photo.jpg").toString()), IncomingIntents.snapshot(send).streams)
        // Some senders put a String.
        val sendString = Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, rec("Photo.jpg").toString())
        assertEquals(listOf(rec("Photo.jpg").toString()), IncomingIntents.snapshot(sendString).streams)

        val multiple = Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(rec("Report.pdf"), rec("Photo.jpg")))
        assertEquals(listOf(rec("Report.pdf").toString(), rec("Photo.jpg").toString()), IncomingIntents.snapshot(multiple).streams)

        val clipOnly = Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/*").apply {
            clipData = ClipData.newRawUri("", rec("Photo.jpg")).apply { addItem(ClipData.Item(rec("Report.pdf"))) }
        }
        assertEquals(listOf(rec("Photo.jpg").toString(), rec("Report.pdf").toString()), IncomingIntents.snapshot(clipOnly).clipUris)

        val text = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "hello")
            .putExtra(Intent.EXTRA_SUBJECT, "Greeting").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        IncomingIntents.snapshot(text).let {
            assertEquals("hello", it.text)
            assertEquals("Greeting", it.subject)
            assertTrue(it.fromHistory)
        }
    }

    @Test
    fun malformedIntentsNeverThrow() {
        val wrong = listOf(
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, 42),
            Intent(Intent.ACTION_SEND_MULTIPLE).putExtra(Intent.EXTRA_STREAM, "not a list"),
            Intent(Intent.ACTION_SEND_MULTIPLE).putExtra(Intent.EXTRA_STREAM, Bundle()),
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, 3.5),
            Intent(Intent.ACTION_VIEW),
            Intent(),
        )
        for (i in wrong) {
            val (s, route) = intents.route(i)
            assertTrue("$s", s.streams.isEmpty())
            assertSame("$s", IncomingRoute.Ignore, route)
        }
        assertSame(IncomingRoute.Ignore, intents.route(null).second)
        // A VIEW of a URI with no usable scheme is not ours: left to the 1.1 handler, which ignores it.
        assertSame(IncomingRoute.Player, intents.route(Intent(Intent.ACTION_VIEW).setData(Uri.parse("::::"))).second)
        // A list with junk in it keeps the URIs.
        val mixed = Intent(Intent.ACTION_SEND_MULTIPLE).putExtra(Intent.EXTRA_STREAM, arrayListOf<android.os.Parcelable>(rec("Photo.jpg"), Bundle()))
        assertEquals(listOf(rec("Photo.jpg").toString()), IncomingIntents.snapshot(mixed).streams)
    }

    @Test
    fun claimedIntentsAreMarkedAndVideosLeftAlone() {
        val pdf = Intent(Intent.ACTION_VIEW).setDataAndType(rec("Report.pdf"), "application/pdf")
        assertTrue(intents.route(pdf).second is IncomingRoute.Incoming)
        intents.markHandled(pdf)
        assertEquals(IncomingIntents.ACTION_HANDLED, pdf.action)
        assertNull(pdf.data)
        assertNull(pdf.type)
        assertSame(IncomingRoute.Ignore, intents.route(pdf).second)

        val share = Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, rec("Photo.jpg"))
        share.clipData = ClipData.newRawUri("", rec("Photo.jpg"))
        intents.markHandled(share)
        assertNull(share.clipData)
        assertFalse(share.hasExtra(Intent.EXTRA_STREAM))

        // Video: VIEW and a single SEND go to the 1.1 path (the provider says video/mp4).
        val video = Intent(Intent.ACTION_VIEW).setDataAndType(rec("Clip.mp4"), "video/mp4")
        assertSame(IncomingRoute.Player, intents.route(video).second)
        val videoShare = Intent(Intent.ACTION_SEND).setType("*/*").putExtra(Intent.EXTRA_STREAM, rec("Clip.mp4"))
        assertSame(IncomingRoute.Player, intents.route(videoShare).second)
        assertEquals(Intent.ACTION_SEND, videoShare.action)
        val stream = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/live.m3u8"))
        assertSame(IncomingRoute.Player, intents.route(stream).second)
    }

    @Test
    fun privateFilesAreRefused() {
        val secret = Uri.fromFile(File(context.filesDir, "secret.db")).toString()
        assertFalse(intents.allowFile(secret))
        assertFalse(intents.allowFile("file:///data/data/${context.packageName}/files/secret.db"))
        assertFalse(intents.allowFile(Uri.fromFile(File(context.cacheDir, "x.pdf")).toString()))
        // Escapes that canonicalize back into the app.
        assertFalse(intents.allowFile("file://${context.filesDir.path}/../files/secret.db"))
        assertFalse(intents.allowFile("file:relative.pdf"))
        assertTrue(intents.allowFile("file:///sdcard/Download/a.pdf"))
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(secret), "application/pdf")
        assertSame(IncomingRoute.Refused, intents.route(view).second)
    }

    // ---------------------------------------------------------------------------------------------
    // Describing

    @Test
    fun describesItemsWithoutOpeningThem() {
        val route = IncomingRoute.Incoming(
            IncomingActionMsg.SEND_MULTIPLE,
            listOf(
                IncomingCandidate(rec("Report.pdf").toString(), null),
                IncomingCandidate(rec("Photo.jpg").toString(), null),
                IncomingCandidate(rec("Report.pdf").toString() + "?again", "application/pdf"),
                IncomingCandidate(rec("Missing.bin").toString(), null),
            ),
        )
        val kept = ArrayList<String>()
        val batch = intents.describe(route, persistable = true, nowMs = 0) { kept.add(it) }!!
        assertEquals(IncomingActionMsg.SEND_MULTIPLE, batch.action)
        assertTrue(batch.batchId.isNotEmpty())
        val items = batch.items
        assertEquals(listOf("Report.pdf", "Photo.jpg"), items.take(2).map { it.displayName })
        assertEquals(listOf("application/pdf", "image/jpeg"), items.take(2).map { it.mimeType })
        assertEquals(listOf(2048L, 777L), items.take(2).map { it.sizeBytes })
        // The provider has no row for a missing file: a fallback name, no size.
        assertNotNull(items[3].displayName)
        assertNull(items[3].sizeBytes)
        // Names are unique in a batch.
        assertEquals(items.size, items.map { it.displayName!!.lowercase() }.toSet().size)
        // Never opened (metadata only), and no grant to keep from our own provider.
        assertTrue(RecordingProvider.modes.isEmpty())
        assertTrue(kept.isEmpty())
    }

    @Test
    fun textShareBecomesAFileThatAcknowledgeRemoves() {
        val route = IncomingRoute.Incoming(IncomingActionMsg.SEND, emptyList(), text = "line 1\nline 2 ✓", subject = "My: notes")
        val batch = intents.describe(route, persistable = false, nowMs = 0) {}!!
        val item = batch.items.single()
        assertEquals("My notes.txt", item.displayName)
        assertEquals("text/plain", item.mimeType)
        val file = File(Uri.parse(item.uri).path!!)
        assertEquals("line 1\nline 2 ✓", file.readText())
        assertEquals(file.length(), item.sizeBytes)
        assertTrue(file.canonicalPath.startsWith(intents.textRoot.canonicalPath))
        intents.deleteBatchFiles(batch.batchId)
        assertFalse(file.exists())
        // Stale directories are swept.
        val old = File(intents.textRoot, "old").apply { mkdirs() }
        old.setLastModified(System.currentTimeMillis() - IncomingIntents.STALE_MS - 60_000)
        intents.sweep(System.currentTimeMillis())
        assertFalse(old.exists())
        // Unsafe ids are ignored.
        intents.deleteBatchFiles("../x")
    }

    // ---------------------------------------------------------------------------------------------
    // The host API behind a fake binding

    private class NoMessenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class FakeBinding(private val activity: Activity) : ActivityPluginBinding {
        val newIntent = ArrayList<PluginRegistry.NewIntentListener>()
        val saveState = ArrayList<ActivityPluginBinding.OnSaveInstanceStateListener>()
        override fun getActivity(): Activity = activity
        override fun getLifecycle(): Any = Any()
        override fun addRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {}
        override fun removeRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {}
        override fun addActivityResultListener(listener: PluginRegistry.ActivityResultListener) {}
        override fun removeActivityResultListener(listener: PluginRegistry.ActivityResultListener) {}
        override fun addOnNewIntentListener(listener: PluginRegistry.NewIntentListener) { newIntent.add(listener) }
        override fun removeOnNewIntentListener(listener: PluginRegistry.NewIntentListener) { newIntent.remove(listener) }
        override fun addOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}
        override fun removeOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}
        override fun addOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}
        override fun removeOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}
        override fun addOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) { saveState.add(listener) }
        override fun removeOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) { saveState.remove(listener) }
    }

    private fun <T> main(block: () -> T): T {
        var out: Result<T>? = null
        instrumentation.runOnMainSync { out = runCatching(block) }
        return out!!.getOrThrow()
    }

    private fun activityWith(intent: Intent): Activity = main { Activity().apply { this.intent = intent } }

    /** Polls takePending on the main thread until a batch shows (the worker posts it back). */
    private fun awaitBatches(api: IncomingHostApiImpl, timeoutMs: Long = 5_000): List<IncomingBatchMsg> {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            val got = main { api.takePending() }
            if (got.isNotEmpty()) return got
            Thread.sleep(50)
        }
        return emptyList()
    }

    /** Attaches like FlutterActivity.onCreate: attach, then restore (null bundle on a fresh launch). */
    private fun coldStart(api: IncomingHostApiImpl, ctx: LibraryPluginContext, activity: Activity, saved: Bundle?): FakeBinding {
        val binding = FakeBinding(activity)
        main {
            ctx.attach(binding)
            binding.saveState.forEach { it.onRestoreInstanceState(saved) }
        }
        return binding
    }

    @Test
    fun coldAndWarmIntentsReachDartOnce() {
        val ctx = LibraryPluginContext(context, NoMessenger(), LibraryEventHub())
        val api = main { IncomingHostApiImpl(ctx) }
        try {
            val launch = Intent(Intent.ACTION_VIEW).setDataAndType(rec("Report.pdf"), "application/pdf")
            val activity = activityWith(launch)
            val binding = coldStart(api, ctx, activity, null)
            // Marked handled synchronously, before MainActivity's handler would read it.
            assertEquals(IncomingIntents.ACTION_HANDLED, activity.intent.action)
            val cold = awaitBatches(api)
            assertEquals(1, cold.size)
            assertEquals(IncomingActionMsg.VIEW, cold[0].action)
            assertEquals("Report.pdf", cold[0].items.single().displayName)
            Thread.sleep(300)
            assertTrue("each batch once", main { api.takePending() }.isEmpty())

            // Warm: a share of two items and a text, through the new-intent listener.
            val warm = Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*")
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(rec("Photo.jpg"), rec("Clip.mp4")))
            assertTrue(main { binding.newIntent.single().onNewIntent(warm) })
            assertEquals(IncomingIntents.ACTION_HANDLED, warm.action)
            val multi = awaitBatches(api).single()
            assertEquals(IncomingActionMsg.SEND_MULTIPLE, multi.action)
            assertEquals(listOf("image/jpeg", "video/mp4"), multi.items.map { it.mimeType })

            val text = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "note")
            assertTrue(main { binding.newIntent.single().onNewIntent(text) })
            val textBatch = awaitBatches(api).single()
            val textFile = File(Uri.parse(textBatch.items.single().uri).path!!)
            assertTrue(textFile.isFile)
            main { api.acknowledge(textBatch.batchId) }
            val end = System.currentTimeMillis() + 3_000
            while (textFile.exists() && System.currentTimeMillis() < end) Thread.sleep(50)
            assertFalse("acknowledge removes the text share", textFile.exists())
            main { api.acknowledge("unknown-id") }

            // Warm video: not ours, left untouched for MainActivity.
            val video = Intent(Intent.ACTION_VIEW).setDataAndType(rec("Clip.mp4"), "video/mp4")
            assertFalse(main { binding.newIntent.single().onNewIntent(video) })
            assertEquals(Intent.ACTION_VIEW, video.action)
            assertEquals(rec("Clip.mp4"), video.data)

            // The saved state marks the launch intent as handled.
            val bundle = Bundle()
            main { binding.saveState.single().onSaveInstanceState(bundle) }
            assertTrue(bundle.keySet().isNotEmpty())
            main { ctx.detach() }
            assertTrue(binding.newIntent.isEmpty())
        } finally {
            main { api.dispose() }
        }
    }

    @Test
    fun recreatedOrRecentsLaunchesAreNotDeliveredAgain() {
        val ctx = LibraryPluginContext(context, NoMessenger(), LibraryEventHub())
        val api = main { IncomingHostApiImpl(ctx) }
        try {
            // Re-created after a configuration change or process death: the saved state says handled.
            val saved = Bundle()
            val first = coldStart(api, ctx, activityWith(Intent(Intent.ACTION_VIEW).setDataAndType(rec("Photo.jpg"), "image/jpeg")), null)
            assertEquals(1, awaitBatches(api).size)
            main { first.saveState.single().onSaveInstanceState(saved) }
            main { ctx.detach() }

            val again = activityWith(Intent(Intent.ACTION_VIEW).setDataAndType(rec("Photo.jpg"), "image/jpeg"))
            coldStart(api, ctx, again, saved)
            assertEquals("still kept from the 1.1 path", IncomingIntents.ACTION_HANDLED, again.intent.action)
            assertTrue(awaitBatches(api, 1_500).isEmpty())
            main { ctx.detach() }

            // Relaunched from Recents.
            val recents = activityWith(
                Intent(Intent.ACTION_VIEW).setDataAndType(rec("Report.pdf"), "application/pdf").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY),
            )
            coldStart(api, ctx, recents, null)
            assertTrue(awaitBatches(api, 1_500).isEmpty())
            main { ctx.detach() }

            // A video launch is never claimed.
            val video = activityWith(Intent(Intent.ACTION_VIEW).setDataAndType(rec("Clip.mp4"), "video/mp4"))
            coldStart(api, ctx, video, null)
            assertEquals(Intent.ACTION_VIEW, video.intent.action)
            assertTrue(awaitBatches(api, 1_000).isEmpty())
            main { ctx.detach() }
        } finally {
            main { api.dispose() }
        }
    }
}
