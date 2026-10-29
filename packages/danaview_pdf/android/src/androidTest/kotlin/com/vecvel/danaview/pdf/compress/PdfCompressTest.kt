// OWNER: HOM-31A
//
// Instrumented tests of the Android compress tool (BUILD_STATE "S4: HOM-31 compress", the HOM-31A
// Android contract), run on API 35, 29 and 28:
// - every preset shrinks the image-heavy fixtures (High > Medium > Small), the pictures still look
//   the same and the text line still extracts;
// - text-only files never grow and keep every page's text (the 200-page HOM-27 file too);
// - an encrypted input stays encrypted with the same password (AES-128, AES-256, owner-only);
// - cancel at every poll, and mid-job through the tools API, leaves no file and no scratch;
// - failures (damaged, wrong password, existing output, a failure after the write) leave no file;
// - the source is never modified (SHA-256 and mtime before and after every run);
// - progress arrives after every page, over the event stream with the job id;
// - the estimate API matches what a run writes (exact) or comes close (sampled);
// - the capabilities list compress.
// Sizes and timings are logged as `HOM31|android-<api>|…` lines (counts only) for BUILD_STATE.

package com.vecvel.danaview.pdf.compress

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.vecvel.danaview.pdf.glue.PdfDocumentHostApiImpl
import com.vecvel.danaview.pdf.glue.PdfEventHub
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfCompressEstimateMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressPresetMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolProgressMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.pigeon.PigeonEventSink
import com.vecvel.danaview.pdf.viewer.awaitCall
import com.vecvel.danaview.pdf.viewer.codeOf
import io.flutter.plugin.common.EventChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class PdfCompressTest {
    private val fx = CompressFixtures
    private val api = Build.VERSION.SDK_INT
    private lateinit var out: File
    private var threads: PdfThreads? = null

    @Before
    fun setUp() {
        out = File(fx.dir, "out_" + UUID.randomUUID()).apply { mkdirs() }
    }

    @After
    fun tearDown() {
        threads?.shutdown()
        out.deleteRecursively()
        assertTrue("no scratch left", scratchDirs().isEmpty())
    }

    private fun scratchDirs(): List<String> =
        fx.context.cacheDir.listFiles().orEmpty().map { it.name }.filter { it.startsWith("dv_pdf_compress_") }

    private fun measured(vararg fields: String) {
        Log.i(HOM31_TAG, (listOf("HOM31", "android-$api") + fields).joinToString("|"))
    }

    private fun saving(before: Long, after: Long) = "saving=%.1f%%".format(100.0 - after * 100.0 / before)

    /** Runs the core on [source] and checks the source is untouched. */
    private fun run(
        source: File,
        preset: PdfCompressPreset,
        password: String? = null,
        target: File = File(out, "${source.nameWithoutExtension}-$preset-${UUID.randomUUID()}.pdf"),
        isCancelled: () -> Boolean = { false },
        progress: (Double, Int, Int) -> Unit = { _, _, _ -> },
    ): Triple<File, PdfCompressOutcome, Long> {
        val hash = fx.sha256(source)
        val mtime = source.lastModified()
        val scratch = File(fx.context.cacheDir, "dv_pdf_compress_test")
        val t0 = SystemClock.elapsedRealtime()
        try {
            val outcome = PdfCompressCore.compress(source, password, preset, target, scratch, isCancelled, progress)
            return Triple(target, outcome, SystemClock.elapsedRealtime() - t0)
        } finally {
            scratch.deleteRecursively()
            assertEquals("source untouched", hash, fx.sha256(source))
            assertEquals("source mtime", mtime, source.lastModified())
        }
    }

    private fun failure(block: () -> Unit): PdfFailure {
        try {
            block()
        } catch (f: PdfFailure) {
            return f
        }
        fail("expected a PdfFailure")
        throw AssertionError()
    }

    // ---- Sizes, pictures and text ----

    @Test
    fun imageHeavyPdfsShrinkWithEveryPresetAndLookTheSame() {
        val cases = listOf(
            Triple("scan", fx.scan, 3),
            Triple("camera", fx.camera, 3),
            Triple("hom27_image_only", fx.asset("image_only_2p.pdf"), 2),
        )
        for ((kind, source, pages) in cases) {
            val before = source.length()
            val sizes = mutableListOf<Long>()
            for (preset in PdfCompressPreset.values()) {
                val (file, outcome, ms) = run(source, preset)
                val after = file.length()
                assertEquals(after, outcome.sizeBytes)
                assertEquals(pages, outcome.pageCount)
                assertTrue("$kind $preset must shrink ($before -> $after)", after < before)
                assertEquals("$kind $preset replaces every picture", outcome.imagesSeen, outcome.imagesReplaced)
                if (kind != "hom27_image_only") {
                    val texts = fx.pageTexts(file)
                    assertEquals(pages, texts.size)
                    for (p in 0 until pages) assertTrue("$kind $preset page $p text", texts[p].contains(fx.token("IMG", p)))
                }
                val diff = fx.pageDifference(source, file)
                assertTrue("$kind $preset looks the same (diff $diff)", diff < 12)
                measured(
                    kind, preset.name.lowercase(), "before=$before", "after=$after", saving(before, after),
                    "replaced=${outcome.imagesReplaced}/${outcome.imagesSeen}", "diff=%.1f".format(diff), "ms=$ms",
                )
                sizes.add(after)
            }
            assertTrue("$kind: High keeps more than Medium $sizes", sizes[0] > sizes[1])
            assertTrue("$kind: Medium keeps more than Small $sizes", sizes[1] > sizes[2])
            assertTrue("$kind: Medium at least halves the file $sizes", sizes[1] < before / 2)
        }
    }

    @Test
    fun textOnlyPdfsNeverGrowAndKeepTheirText() {
        for ((kind, source, prefix) in listOf(Triple("text", fx.text, "TXT"), Triple("hom27_text_200p", fx.asset("text_200p.pdf"), "HOM27T"))) {
            val before = source.length()
            val pages = if (kind == "text") 3 else 200
            for (preset in PdfCompressPreset.values()) {
                val pagesSeen = mutableListOf<Int>()
                val (file, outcome, ms) = run(source, preset) { _, done, _ -> pagesSeen.add(done) }
                assertEquals(pages, outcome.pageCount)
                assertEquals(0, outcome.imagesSeen)
                assertTrue("$kind $preset must not grow", file.length() <= before)
                assertEquals(before, file.length())
                assertTrue("progress after every page", pagesSeen.containsAll((1..pages).toList()))
                val texts = fx.pageTexts(file)
                assertEquals(pages, texts.size)
                for (p in 0 until pages) {
                    val token = if (kind == "text") fx.token(prefix, p) else "HOM27T-P%04d".format(p + 1)
                    assertTrue("$kind $preset page $p text", texts[p].contains(token))
                }
                measured(kind, preset.name.lowercase(), "before=$before", "after=${file.length()}", "text=extractable", "ms=$ms")
            }
        }
    }

    @Test
    fun textOnImagePagesStaysExtractableAfterRewrite() {
        // The image-heavy outputs are real rewrites (images replaced); the text line is still text.
        val (file, outcome, _) = run(fx.scan, PdfCompressPreset.SMALL)
        assertTrue(outcome.imagesReplaced > 0)
        PDDocument.load(file).use { doc ->
            assertEquals(3, doc.numberOfPages)
            val fonts = doc.getPage(0).resources.fontNames.toList()
            assertTrue("fonts kept", fonts.isNotEmpty())
        }
        val texts = fx.pageTexts(file)
        for (p in 0 until 3) assertTrue(texts[p].contains("${fx.token("IMG", p)} scanned page"))
    }

    // ---- Encryption ----

    @Test
    fun encryptedInputsStayEncryptedWithTheSamePassword() {
        for (keyLength in listOf(128, 256)) {
            val source = fx.imagePdf(
                "enc_$keyLength.pdf", pages = 3, jpeg = true, ppi = 150, prefix = "ENC",
                protect = fx.policy(CompressFixtures.OWNER_PASSWORD, CompressFixtures.USER_PASSWORD, keyLength),
            )
            val before = source.length()
            for (preset in PdfCompressPreset.values()) {
                val (file, outcome, ms) = run(source, preset, password = CompressFixtures.USER_PASSWORD)
                assertTrue(outcome.imagesReplaced > 0)
                assertTrue("aes$keyLength $preset shrinks", file.length() < before)
                try {
                    PDDocument.load(file).close()
                    fail("aes$keyLength $preset: output opens without the password")
                } catch (e: InvalidPasswordException) {
                    // expected
                }
                PDDocument.load(file, CompressFixtures.USER_PASSWORD).use { doc ->
                    assertTrue(doc.isEncrypted)
                    assertEquals(keyLength, doc.encryption.length)
                    assertEquals(3, doc.numberOfPages)
                }
                val texts = fx.pageTexts(file, CompressFixtures.USER_PASSWORD)
                for (p in 0 until 3) assertTrue(texts[p].contains(fx.token("ENC", p)))
                measured("encrypted_aes$keyLength", preset.name.lowercase(), "before=$before", "after=${file.length()}", saving(before, file.length()), "ms=$ms")
            }
            // Without the password: passwordRequired and no file.
            val target = File(out, "locked.pdf")
            assertEquals("passwordRequired", failure { run(source, PdfCompressPreset.MEDIUM, target = target) }.code.name)
            assertEquals("passwordRequired", failure { run(source, PdfCompressPreset.MEDIUM, password = "wrong", target = target) }.code.name)
            assertFalse(target.exists())
        }
    }

    @Test
    fun ownerOnlyRestrictionsAreKept() {
        val perms = AccessPermission().apply {
            setCanExtractContent(false)
            setCanModify(false)
        }
        val source = fx.imagePdf("owner_only.pdf", pages = 2, jpeg = true, ppi = 150, prefix = "OWN", protect = fx.policy(CompressFixtures.OWNER_PASSWORD, "", 128, perms))
        val (file, outcome, _) = run(source, PdfCompressPreset.MEDIUM)
        assertTrue(outcome.imagesReplaced > 0)
        assertTrue(file.length() < source.length())
        PDDocument.load(file).use { doc ->
            assertTrue(doc.isEncrypted)
            assertFalse(doc.currentAccessPermission.isOwnerPermission)
            assertFalse(doc.currentAccessPermission.canExtractContent())
            assertFalse(doc.currentAccessPermission.canModify())
        }
    }

    // ---- Cancel and failure ----

    @Test
    fun cancelAtEveryPollLeavesNoFile() {
        val source = fx.asset("image_only_2p.pdf")
        var polls = 0
        run(source, PdfCompressPreset.SMALL, isCancelled = { polls++; false })
        assertTrue("polled per page and per image ($polls)", polls >= 4)
        for (k in 0 until polls) {
            var n = 0
            val target = File(out, "cancel_$k.pdf")
            val f = failure { run(source, PdfCompressPreset.SMALL, target = target, isCancelled = { n++ >= k }) }
            assertEquals("poll $k", "cancelled", f.code.name)
            assertFalse("poll $k leaves no file", target.exists())
        }
        assertTrue(out.listFiles().orEmpty().none { it.name.startsWith("cancel_") })
    }

    @Test
    fun failuresLeaveNoFile() {
        // Damaged input.
        val damaged = File(fx.dir, "damaged.pdf").apply { writeBytes(ByteArray(64 * 1024).also { java.util.Random(31).nextBytes(it) }) }
        val target = File(out, "damaged_out.pdf")
        assertEquals("damaged", failure { run(damaged, PdfCompressPreset.MEDIUM, target = target) }.code.name)
        assertFalse(target.exists())
        // An existing output is never replaced.
        val existing = File(out, "exists.pdf").apply { writeText("keep") }
        assertEquals("invalidArgument", failure { run(fx.text, PdfCompressPreset.MEDIUM, target = existing) }.code.name)
        assertEquals("keep", existing.readText())
        // A failure after the file was written: deleted again.
        val late = File(out, "late.pdf")
        try {
            run(fx.asset("image_only_2p.pdf"), PdfCompressPreset.MEDIUM, target = late) { fraction, _, _ ->
                if (fraction >= 1.0) throw IllegalStateException("late failure")
            }
            fail("expected the late failure")
        } catch (e: IllegalStateException) {
            // expected
        }
        assertFalse("late failure leaves no file", late.exists())
    }

    @Test
    fun progressAfterEveryPage() {
        val calls = mutableListOf<Triple<Double, Int, Int>>()
        run(fx.camera, PdfCompressPreset.MEDIUM) { f, d, t -> calls.add(Triple(f, d, t)) }
        assertEquals(listOf(0, 1, 2, 3, 3), calls.map { it.second })
        assertTrue(calls.all { it.third == 3 })
        val fractions = calls.map { it.first }
        assertEquals(fractions.sorted(), fractions)
        assertEquals(1.0, fractions.last(), 0.0)
    }

    // ---- Through the plugin's APIs ----

    private class Events : EventChannel.EventSink {
        val progress = CopyOnWriteArrayList<PdfToolProgressMsg>()
        var onProgress: (PdfToolProgressMsg) -> Unit = {}

        override fun success(event: Any?) {
            val e = event as PdfEventMsg
            assertEquals(PdfEventKindMsg.TOOL_PROGRESS, e.kind)
            val p = e.toolProgress!!
            progress.add(p)
            onProgress(p)
        }

        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = fail("event error $errorCode")

        override fun endOfStream() {}
    }

    private fun plugin(): Triple<PdfCompressor, PdfToolsHostApiImpl, Events> {
        val main = Handler(Looper.getMainLooper())
        val hub = PdfEventHub(main)
        val events = Events()
        hub.onListen(null, PigeonEventSink(events))
        val compressor = PdfCompressor(main, hub, fx.context.cacheDir)
        val t = PdfThreads().also { threads = it }
        return Triple(compressor, PdfToolsHostApiImpl(t, hub::emit, compressor), events)
    }

    private fun request(jobId: String, source: File, preset: PdfCompressPresetMsg, target: File, password: String? = null, isImage: Boolean = false) =
        PdfCompressRequestMsg(jobId, PdfToolInputMsg(source.absolutePath, password, isImage), preset, target.absolutePath)

    @Test
    fun toolsApiCompressesWithProgressEventsPerPage() {
        val (compressor, tools, events) = plugin()
        val target = File(out, "api.pdf")
        val result = awaitCall<PdfToolResultMsg>(120_000) { cb -> tools.compress(request("job-1", fx.camera, PdfCompressPresetMsg.SMALL, target), cb) }
        val msg = result.getOrThrow()
        assertEquals(listOf(target.absolutePath), msg.outPaths)
        assertEquals(listOf(3L), msg.pageCounts)
        assertEquals(listOf(target.length()), msg.sizesBytes)
        assertTrue(target.length() < fx.camera.length())
        // Progress events are posted to the main thread before the reply.
        val progress = events.progress.toList()
        assertTrue(progress.all { it.jobId == "job-1" && it.tool == PdfToolKindMsg.COMPRESS })
        assertTrue("an event after every page", progress.map { it.pagesDone }.containsAll(listOf(1L, 2L, 3L)))
        assertEquals(1.0, progress.last().fraction, 0.0)
        assertEquals(progress.map { it.fraction }.sorted(), progress.map { it.fraction })
        compressor.shutdown()
    }

    @Test
    fun toolsApiCancelMidJobLeavesNoFile() {
        val (compressor, tools, events) = plugin()
        val target = File(out, "cancelled.pdf")
        events.onProgress = { p -> if (p.pagesDone >= 1) tools.cancel("job-c") }
        val t0 = SystemClock.elapsedRealtime()
        val result = awaitCall<PdfToolResultMsg>(120_000) { cb -> tools.compress(request("job-c", fx.scan, PdfCompressPresetMsg.HIGH, target), cb) }
        assertEquals("cancelled", codeOf(result))
        assertFalse(target.exists())
        assertTrue("cancelled before the last page", events.progress.none { it.pagesDone == 3L })
        measured("cancel_mid_job", "high", "ms=${SystemClock.elapsedRealtime() - t0}")
        compressor.shutdown()
    }

    @Test
    fun toolsApiRejectsBadRequestsTyped() {
        val (compressor, tools, _) = plugin()
        val target = File(out, "bad.pdf")
        assertEquals("invalidArgument", codeOf(awaitCall<PdfToolResultMsg> { cb -> tools.compress(request("i", fx.text, PdfCompressPresetMsg.HIGH, target, isImage = true), cb) }))
        assertEquals("notFound", codeOf(awaitCall<PdfToolResultMsg> { cb -> tools.compress(request("n", File(fx.dir, "missing.pdf"), PdfCompressPresetMsg.HIGH, target), cb) }))
        val damaged = File(fx.dir, "random.pdf").apply { writeBytes(ByteArray(8192) { (it * 31).toByte() }) }
        assertEquals("damaged", codeOf(awaitCall<PdfToolResultMsg> { cb -> tools.compress(request("d", damaged, PdfCompressPresetMsg.HIGH, target), cb) }))
        assertFalse(target.exists())
        // A job id in use is refused; the running job is unaffected.
        val first = File(out, "first.pdf")
        val results = CopyOnWriteArrayList<Result<PdfToolResultMsg>>()
        val second = awaitCall<PdfToolResultMsg>(120_000) { cb ->
            tools.compress(request("dup", fx.camera, PdfCompressPresetMsg.MEDIUM, first)) { results.add(it) }
            tools.compress(request("dup", fx.camera, PdfCompressPresetMsg.MEDIUM, File(out, "second.pdf")), cb)
        }
        assertEquals("invalidArgument", codeOf(second))
        val firstDone = awaitCall<PdfCompressEstimateMsg>(120_000) { cb -> compressor.estimate(PdfToolInputMsg(fx.text.absolutePath, null, false), cb) }
        assertNotNull(firstDone.getOrThrow())
        assertEquals(1, results.size)
        assertTrue(results[0].isSuccess)
        assertTrue(first.exists())
        compressor.shutdown()
    }

    // ---- Estimate ----

    @Test
    fun estimateMatchesRunsExactlyForShortFiles() {
        val (compressor, _, _) = plugin()
        for ((kind, source) in listOf("camera" to fx.camera, "hom27_image_only" to fx.asset("image_only_2p.pdf"), "text" to fx.text)) {
            val t0 = SystemClock.elapsedRealtime()
            val e = awaitCall<PdfCompressEstimateMsg>(180_000) { cb -> compressor.estimate(PdfToolInputMsg(source.absolutePath, null, false), cb) }.getOrThrow()
            val ms = SystemClock.elapsedRealtime() - t0
            assertFalse(e.sampled)
            assertEquals(source.length(), e.sourceBytes)
            val written = PdfCompressPreset.values().map { run(source, it).first.length() }
            assertEquals("$kind exact", written, listOf(e.highBytes, e.mediumBytes, e.smallBytes))
            measured("estimate_$kind", "high=${e.highBytes}", "medium=${e.mediumBytes}", "small=${e.smallBytes}", "sampled=false", "ms=$ms")
        }
        // Encrypted: exact too (same write, same encryption).
        val enc = fx.imagePdf("enc_estimate.pdf", pages = 2, jpeg = true, ppi = 150, prefix = "ENC", protect = fx.policy(CompressFixtures.OWNER_PASSWORD, CompressFixtures.USER_PASSWORD, 128))
        val e = awaitCall<PdfCompressEstimateMsg>(180_000) { cb -> compressor.estimate(PdfToolInputMsg(enc.absolutePath, CompressFixtures.USER_PASSWORD, false), cb) }.getOrThrow()
        assertEquals(run(enc, PdfCompressPreset.MEDIUM, password = CompressFixtures.USER_PASSWORD).first.length(), e.mediumBytes)
        assertEquals("passwordRequired", codeOf(awaitCall<PdfCompressEstimateMsg> { cb -> compressor.estimate(PdfToolInputMsg(enc.absolutePath, null, false), cb) }))
        compressor.shutdown()
    }

    @Test
    fun estimateSamplesLongFiles() {
        val (compressor, _, _) = plugin()
        val nine = fx.imagePdf("camera_9p.pdf", pages = 9, jpeg = true, ppi = 150)
        val t0 = SystemClock.elapsedRealtime()
        val e = awaitCall<PdfCompressEstimateMsg>(180_000) { cb -> compressor.estimate(PdfToolInputMsg(nine.absolutePath, null, false), cb) }.getOrThrow()
        val ms = SystemClock.elapsedRealtime() - t0
        assertTrue(e.sampled)
        val medium = run(nine, PdfCompressPreset.MEDIUM).first.length()
        val error = Math.abs(e.mediumBytes - medium).toDouble() / medium
        assertTrue("sampled Medium within 25 % (${e.mediumBytes} vs $medium)", error < 0.25)
        measured("estimate_camera_9p", "medium_est=${e.mediumBytes}", "medium_run=$medium", "error=%.1f%%".format(error * 100), "ms=$ms")

        val text200 = fx.asset("text_200p.pdf")
        val t1 = SystemClock.elapsedRealtime()
        val t = awaitCall<PdfCompressEstimateMsg>(180_000) { cb -> compressor.estimate(PdfToolInputMsg(text200.absolutePath, null, false), cb) }.getOrThrow()
        assertTrue(t.sampled)
        assertEquals(listOf(text200.length(), text200.length(), text200.length()), listOf(t.highBytes, t.mediumBytes, t.smallBytes))
        measured("estimate_text_200p", "all=${t.highBytes}", "sampled=true", "ms=${SystemClock.elapsedRealtime() - t1}")
        compressor.shutdown()
    }

    // ---- Capabilities ----

    @Test
    fun capabilitiesListCompress() {
        assertTrue(PdfToolKindMsg.COMPRESS in PdfDocumentHostApiImpl.capabilitiesMessage().tools)
    }
}
