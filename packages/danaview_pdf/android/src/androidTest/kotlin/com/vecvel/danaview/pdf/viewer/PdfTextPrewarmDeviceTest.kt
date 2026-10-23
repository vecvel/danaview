// OWNER: HOM-25
//
// Instrumented tests of the page-text pre-warm below API 35 (text/PdfTextPrewarm.kt, lead 9d15fe3e
// answer 3), through the real host APIs: a texture view's first complete frame starts it, a first
// search afterwards is faster (timings logged under HOM25), a search during it is complete, closing
// the document mid-way stops it and leaves no thread, a 501-page file (generated here) is not
// pre-warmed, and nothing is pre-warmed from API 35.

package com.vecvel.danaview.pdf.viewer

import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.vecvel.danaview.pdf.glue.PdfDocumentHostApiImpl
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfDisplayModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewRequestMsg
import com.vecvel.danaview.pdf.text.PdfCancelToken
import com.vecvel.danaview.pdf.text.PdfSearch
import com.vecvel.danaview.pdf.text.TextPrewarmJob
import com.vecvel.danaview.pdf.text.TextPrewarmPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PdfTextPrewarmDeviceTest {
    private val store = PdfDocumentStore()
    private val threads = PdfThreads()
    private val textures = FakeTextureRegistry()
    private val views = PdfViewHostApiImpl(store, textures, threads)
    private val documents = PdfDocumentHostApiImpl(store, threads)

    private val below35 get() = Build.VERSION.SDK_INT < TextPrewarmPolicy.PLATFORM_TEXT_API

    @After
    fun tearDown() {
        onMain { views.disposeAll() }
        store.removeAll().forEach { doc -> threads.render.post { doc.release() } }
        threads.render.post { threads.shutdown() }
    }

    /** Opens [path] and shows it in a texture view until its first complete frame. */
    private fun openAndShow(path: String): Pair<OpenPdf, PdfTextureViewMsg> {
        val s = store.open(path, null)
        val msg = awaitCall<PdfTextureViewMsg> {
            views.createTextureView(PdfTextureViewRequestMsg(s.handle, 1080, 2340, 0, PdfDisplayModeMsg.CONTINUOUS), it)
        }.getOrThrow()
        awaitComplete(onMain { views.view(msg.viewId) }, 0)
        return store.get(s.handle) to msg
    }

    private fun waitFor(timeoutMs: Long, what: String, test: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (test()) return
            Thread.sleep(10)
        }
        throw AssertionError("timed out: $what")
    }

    private fun searchMs(doc: OpenPdf, query: String): Pair<Double, Int> {
        val t0 = System.nanoTime()
        val r = PdfSearch.search(doc, query, caseSensitive = false, maxHits = 500, token = PdfCancelToken())
        return (System.nanoTime() - t0) / 1e6 to r.hits.size
    }

    @Test
    fun firstSearchAfterThePrewarmWaitsOnlyOnWhatIsLeft() {
        assumeTrue("pre-warm runs below API 35", below35)
        val path = Fixtures.path(Fixtures.TEXT_200)
        // Warm the code paths on another file so the baseline is a first search, not a cold JIT.
        PdfSearch.search(store.get(store.open(Fixtures.path(Fixtures.MERGE_3), null).handle), "HOM27M", false, 10, PdfCancelToken())

        // Before: no view, so no pre-warm; the last page's token makes the search read every page.
        val plain = store.get(store.open(path, null).handle)
        val (beforeMs, beforeHits) = searchMs(plain, "hom27t-p0200")
        assertEquals(1, beforeHits)
        assertNull(threads.prewarm.job(plain.handle))

        // Partial: search 3 s after the first frame.
        val (partial, _) = openAndShow(path)
        Thread.sleep(PARTIAL_WAIT_MS)
        val cachedAtSearch = partial.cachedTextPages
        val (partialMs, partialHits) = searchMs(partial, "hom27t-p0200")
        assertEquals(1, partialHits)

        // Full: search once the pre-warm finished.
        val t0 = System.nanoTime()
        val (full, _) = openAndShow(path)
        val job = threads.prewarm.job(full.handle) ?: error("no pre-warm scheduled")
        waitFor(120_000, "pre-warm done") { job.isFinished }
        val warmMs = (System.nanoTime() - t0) / 1e6
        assertEquals(TextPrewarmJob.State.DONE, job.state)
        assertEquals(200, full.cachedTextPages)
        val (afterMs, afterHits) = searchMs(full, "hom27t-p0200")
        assertEquals(1, afterHits)

        Log.i(
            HOM25_TAG,
            "pre-warm text_200p (API ${Build.VERSION.SDK_INT}): first search without pre-warm %.0f ms; %d s after first frame (%d/200 pages cached) %.0f ms; after the full pre-warm (%.0f ms from open) %.0f ms"
                .format(beforeMs, PARTIAL_WAIT_MS / 1000, cachedAtSearch, partialMs, warmMs, afterMs),
        )
        assertTrue("after $afterMs ms vs before $beforeMs ms", afterMs < beforeMs / 4)
        assertTrue("partial $partialMs ms vs before $beforeMs ms", cachedAtSearch == 0 || partialMs < beforeMs)
    }

    @Test
    fun searchDuringThePrewarmFindsEveryPage() {
        assumeTrue(below35)
        val (doc, _) = openAndShow(Fixtures.path(Fixtures.TEXT_200))
        val job = threads.prewarm.job(doc.handle) ?: error("no pre-warm scheduled")
        waitFor(60_000, "20 pages warmed") { job.pagesWarmed >= 20 }
        val r = PdfSearch.search(doc, "HOM27T-P", false, 500, PdfCancelToken())
        assertEquals((0 until 200).toList(), r.hits.map { it.match.pageIndex })
        assertTrue(r.hits.all { it.bounds[2] > 0f })
        waitFor(120_000, "pre-warm done") { job.isFinished }
        assertEquals(TextPrewarmJob.State.DONE, job.state)
        assertEquals(200, doc.cachedTextPages)
    }

    @Test
    fun closingMidPrewarmStopsItAndLeavesNoThread() {
        assumeTrue(below35)
        val (doc, msg) = openAndShow(Fixtures.path(Fixtures.TEXT_200))
        val job = threads.prewarm.job(doc.handle) ?: error("no pre-warm scheduled")
        waitFor(60_000, "pre-warm running") { job.pagesWarmed >= 2 }
        val t0 = System.nanoTime()
        onMain { documents.close(doc.handle) }
        waitFor(5_000, "pre-warm stopped") { job.isFinished }
        val stopMs = (System.nanoTime() - t0) / 1e6
        assertEquals(TextPrewarmJob.State.CANCELLED, job.state)
        val warmed = job.pagesWarmed
        assertTrue("stopped at $warmed pages", warmed < 200)
        assertNull(threads.prewarm.job(doc.handle))
        onMain { views.disposeTextureView(msg.viewId) }
        waitFor(10_000, "document closed") { doc.closed }
        waitFor(5_000, "pre-warm thread gone") { threads.prewarm.threadCount == 0 }
        val named = Thread.getAllStackTraces().keys.count { it.isAlive && it.name == "danaview-pdf-prewarm" }
        Log.i(HOM25_TAG, "pre-warm close (API ${Build.VERSION.SDK_INT}): stopped %.0f ms after close at %d pages; prewarm threads alive in process: %d".format(stopMs, warmed, named))
        assertEquals(warmed, job.pagesWarmed)
    }

    @Test
    fun documentsOver500PagesAreNotPrewarmed() {
        val file = File(Fixtures.context.cacheDir, "hom25_prewarm_501p.pdf")
        try {
            PDDocument().use { pdf ->
                for (i in 0 until 501) {
                    val page = PDPage(PDRectangle.A4)
                    pdf.addPage(page)
                    PDPageContentStream(pdf, page).use { cs ->
                        cs.beginText()
                        cs.setFont(PDType1Font.HELVETICA, 11f)
                        cs.newLineAtOffset(56f, 746f)
                        cs.showText("Token BIG-P%04d".format(i + 1))
                        cs.endText()
                    }
                }
                pdf.save(file)
            }
            val (doc, _) = openAndShow(file.absolutePath)
            assertEquals(501, doc.pages.size)
            Thread.sleep(1_500)
            assertNull("no pre-warm over 500 pages", threads.prewarm.job(doc.handle))
            assertEquals(0, doc.cachedTextPages)
            assertEquals(0, threads.prewarm.threadCount)
            // On demand still works.
            val hit = PdfSearch.search(doc, "big-p0501", false, 10, PdfCancelToken()).hits.single()
            assertEquals(500, hit.match.pageIndex)
        } finally {
            file.delete()
        }
    }

    @Test
    fun nothingIsPrewarmedFromApi35() {
        assumeTrue(!below35)
        val (doc, _) = openAndShow(Fixtures.path(Fixtures.TEXT_200))
        Thread.sleep(1_000)
        assertNull(threads.prewarm.job(doc.handle))
        assertEquals(0, doc.cachedTextPages)
    }

    private companion object {
        const val PARTIAL_WAIT_MS = 3_000L
    }
}
