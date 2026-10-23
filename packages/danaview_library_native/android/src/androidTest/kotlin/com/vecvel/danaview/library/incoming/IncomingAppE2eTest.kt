// OWNER: HOM-21A
//
// End-to-end check of Android incoming intents against the installed Danaview app (debug build of
// this tree, com.vecvel.danaview; skipped when it is not installed). This test APK is the sender:
// it serves its files through the library's own FileProvider (<cacheDir>/danaview-out/, granted
// read-only per intent, as a real sender's provider would) and starts Danaview with
// ACTION_VIEW / ACTION_SEND / ACTION_SEND_MULTIPLE; the Files app (DocumentsUI) shares too.
// Danaview's plugin logs one count-only line per batch (tag DanaviewIncoming, rule 30), read from
// logcat. Checks:
// - cold start (app stopped) and warm start (app running) VIEW of a PDF -> one batch each;
// - SEND_MULTIPLE of a PDF, a photo and a video; SEND of text; SEND of one photo -> batches;
// - VIEW and a single SEND of a video -> no batch: the 1.1 path copies it into cache/open_with
//   for the player, as before (P-7);
// - a malformed SEND (EXTRA_STREAM of the wrong type) and a VIEW of Danaview's own private file
//   do not crash the app and deliver nothing;
// - the real Files app: tap a PDF ("Open with" Danaview) and share two items to Danaview.

package com.vecvel.danaview.library.incoming

import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import com.vecvel.danaview.library.pickers.SystemUi
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

@RunWith(AndroidJUnit4::class)
class IncomingAppE2eTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val outDir get() = File(context.cacheDir, "danaview-out/hom21a-e2e")
    private val seeded = ArrayList<Uri>()

    @Before
    fun setUp() {
        assumeTrue("Danaview app not installed", runCatching { context.packageManager.getPackageInfo(APP, 0) }.isSuccess)
        // An older build without the INT-104 filters (no SEND_MULTIPLE of a PDF) can't take part.
        val probe = Intent(Intent.ACTION_SEND_MULTIPLE).setType("application/pdf").setPackage(APP)
        @Suppress("DEPRECATION")
        assumeTrue("installed Danaview predates HOM-21A", context.packageManager.queryIntentActivities(probe, 0).isNotEmpty())
        outDir.mkdirs()
        File(outDir, "Report.pdf").writeBytes(pdfBytes())
        File(outDir, "Photo.jpg").writeBytes(ByteArray(4096) { (it * 7).toByte() })
        File(outDir, "Clip.mp4").writeBytes(ByteArray(8192) { (it * 3).toByte() })
        shell("logcat -c")
    }

    @After
    fun tearDown() {
        outDir.deleteRecursively()
        seeded.forEach { runCatching { context.contentResolver.delete(it, null, null) } }
        shell("am force-stop $APP")
    }

    private fun pdfBytes(): ByteArray = (
        "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" +
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
        ).toByteArray()

    private fun shell(cmd: String): String {
        val pfd = instrumentation.uiAutomation.executeShellCommand(cmd)
        return ParcelStream(pfd).use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private class ParcelStream(pfd: android.os.ParcelFileDescriptor) : java.io.InputStream() {
        private val input = android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd)
        override fun read(): Int = input.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = input.read(b, off, len)
        override fun close() = input.close()
    }

    private fun shared(name: String): Uri = FileProvider.getUriForFile(context, "${context.packageName}.danaview.library.files", File(outDir, name))

    private fun send(intent: Intent) {
        intent.setPackage(APP).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(intent)
    }

    private fun incomingLines(): List<String> =
        shell("logcat -d -s DanaviewIncoming:I").lines().filter { it.contains("incoming:") }

    /** Waits for the [n]th "batch" line and returns it. */
    private fun awaitBatch(n: Int, timeoutMs: Long = 30_000): String {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            val batches = incomingLines().filter { it.contains(" batch, ") }
            if (batches.size >= n) return batches[n - 1]
            Thread.sleep(300)
        }
        error("no batch #$n; log:\n" + incomingLines().joinToString("\n"))
    }

    private fun pid(): String = shell("pidof $APP").trim()

    private fun awaitPid(timeoutMs: Long = 30_000): String {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            pid().takeIf { it.isNotEmpty() }?.let { return it }
            Thread.sleep(300)
        }
        error("app not running")
    }

    private fun openWithCopies(): List<String> =
        shell("run-as $APP ls cache/open_with").lines().map { it.trim() }.filter { it.isNotEmpty() && !it.contains("No such file") }

    @Test
    fun intentsFromAnotherApp() {
        shell("am force-stop $APP")
        shell("run-as $APP rm -rf cache/open_with")

        // Cold start: VIEW of a PDF.
        send(Intent(Intent.ACTION_VIEW).setDataAndType(shared("Report.pdf"), "application/pdf"))
        val first = awaitBatch(1, 60_000)
        assertTrue(first, first.contains("view batch, 1 item(s)"))
        val pid = awaitPid()

        // Warm: the same VIEW again is a new intent -> a second batch, same process.
        send(Intent(Intent.ACTION_VIEW).setDataAndType(shared("Report.pdf"), "application/pdf"))
        assertTrue(awaitBatch(2).contains("view batch, 1 item(s)"))

        // SEND_MULTIPLE of a PDF, a photo and a video (all imported), with ClipData as the share sheet sets it.
        val uris = arrayListOf(shared("Report.pdf"), shared("Photo.jpg"), shared("Clip.mp4"))
        send(
            Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*").putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris).apply {
                clipData = ClipData.newRawUri("", uris[0]).apply { addItem(ClipData.Item(uris[1])); addItem(ClipData.Item(uris[2])) }
            },
        )
        assertTrue(awaitBatch(3).contains("send_multiple batch, 3 item(s), 0 dropped"))

        // SEND of text, SEND of one photo.
        send(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Shared from the HOM-21A test"))
        assertTrue(awaitBatch(4).contains("send batch, 1 item(s)"))
        send(Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, shared("Photo.jpg")))
        assertTrue(awaitBatch(5).contains("send batch, 1 item(s)"))

        // Video: VIEW and single SEND take the 1.1 path (copied for the player), no batch.
        send(Intent(Intent.ACTION_VIEW).setDataAndType(shared("Clip.mp4"), "video/mp4"))
        var end = System.currentTimeMillis() + 20_000
        while (openWithCopies().isEmpty() && System.currentTimeMillis() < end) Thread.sleep(300)
        assertEquals(listOf("Clip.mp4"), openWithCopies())
        shell("run-as $APP rm -rf cache/open_with")
        send(Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, shared("Clip.mp4")))
        end = System.currentTimeMillis() + 20_000
        while (openWithCopies().isEmpty() && System.currentTimeMillis() < end) Thread.sleep(300)
        assertEquals(listOf("Clip.mp4"), openWithCopies())

        // Malformed and refused intents: no crash, nothing delivered.
        send(Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, 42))
        send(Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/png").putExtra(Intent.EXTRA_STREAM, "nope"))
        // A file:// URI can't leave an app on API 24+ (FileUriExposedException), so the shell sends it.
        shell("am start -a android.intent.action.VIEW -t text/plain -d file:///data/data/$APP/shared_prefs/x.xml -n $APP/.MainActivity")
        Thread.sleep(3_000)
        assertEquals(5, incomingLines().count { it.contains(" batch, ") })
        assertTrue(incomingLines().any { it.contains("refused") })
        assertEquals("the app kept running", pid, pid())
        assertTrue(shell("logcat -d -b crash").lines().none { it.contains(APP) })
    }

    @Test
    fun filesAppOpenWithAndShare() {
        assumeTrue("MediaStore Downloads needs API 29", Build.VERSION.SDK_INT >= 29)
        shell("am force-stop $APP")
        val stamp = System.currentTimeMillis() % 100000
        val pdf = "HOM21A_$stamp.pdf"
        val jpg = "HOM21A_$stamp.jpg"
        seed(pdf, "application/pdf", pdfBytes())
        seed(jpg, "image/jpeg", File(outDir, "Photo.jpg").readBytes())

        // Open the Files app on Downloads.
        val files = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse("content://com.android.providers.downloads.documents/root/downloads"), "vnd.android.document/root")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        context.startActivity(files)

        // Share both: long-press, tap, Share, Danaview in the share sheet.
        val first = SystemUi.listed(pdf, 15_000) ?: error("$pdf not listed:\n" + SystemUi.dump())
        first.longClick()
        Thread.sleep(800)
        (SystemUi.listed(jpg, 5_000) ?: error("$jpg not listed:\n" + SystemUi.dump())).click()
        Thread.sleep(500)
        val share = SystemUi.waitAny(5_000, SystemUi.byDesc("(?i)^share$"), SystemUi.byRes(".*:id/action_menu_share"))
            ?: error("no Share action:\n" + SystemUi.dump())
        share.click()
        val target = SystemUi.waitAny(15_000, SystemUi.byText("^Danaview$")) ?: error("Danaview not in the share sheet:\n" + SystemUi.dump())
        target.click()
        val line = awaitBatch(1, 60_000)
        assertTrue(line, line.contains("send_multiple batch, 2 item(s)"))

        // Open with: tap the PDF in Files (Danaview may be the only PDF handler, else pick it).
        context.startActivity(files)
        val again = SystemUi.listed(pdf, 15_000) ?: error("$pdf not listed:\n" + SystemUi.dump())
        again.click()
        SystemUi.waitAny(5_000, SystemUi.byText("^Danaview$"))?.let { choice ->
            choice.click()
            SystemUi.waitAny(3_000, SystemUi.byText("(?i)^just once$"))?.click()
        }
        val view = awaitBatch(2, 60_000)
        assertTrue(view, view.contains("view batch, 1 item(s)"))
        assertNotNull(SystemUi.device.findObject(By.pkg(Pattern.compile(Pattern.quote(APP)))) ?: SystemUi.device.wait(
            androidx.test.uiautomator.Until.findObject(By.pkg(APP)), 10_000,
        ))
    }

    private fun seed(name: String, mime: String, bytes: ByteArray) {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("seed failed")
        seeded.add(uri)
        context.contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
    }

    private companion object {
        const val APP = "com.vecvel.danaview"
    }
}
