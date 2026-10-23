// OWNER: HOM-25
//
// Instrumented tests of the text layer (HOM-25, PdfBox-Android): extraction for the search index
// (ranges, limits, every token of every fixture page, the /Rotate 90 page, passwords, damaged
// files) and in-document search (offsets, bounds in page space, case rules, maxHits, cancel), on
// every API level.

package com.vecvel.danaview.pdf.viewer

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfTextRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextResultMsg
import com.vecvel.danaview.pdf.text.PdfCancelToken
import com.vecvel.danaview.pdf.text.PageText
import com.vecvel.danaview.pdf.text.PdfBoxTextReader
import com.vecvel.danaview.pdf.text.PdfSearch
import com.vecvel.danaview.pdf.text.PdfTextExtraction
import com.vecvel.danaview.pdf.text.PdfTextHostApiImpl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfTextTest {
    private val store = PdfDocumentStore()

    @After
    fun tearDown() {
        store.removeAll().forEach { it.release() }
    }

    private fun code(block: () -> Unit): PdfErrorCode {
        try {
            block()
        } catch (f: PdfFailure) {
            return f.code
        }
        fail("expected a PdfFailure")
        error("unreachable")
    }

    private fun token(prefix: String, page: Int) = "%s-P%04d".format(prefix, page + 1)

    @Test
    fun extractsEveryPageOfTheTimingFile() {
        val t0 = System.nanoTime()
        val r = PdfTextExtraction.extract(Fixtures.path(Fixtures.TEXT_200), null, 0, -1, -1)
        val ms = (System.nanoTime() - t0) / 1e6
        Log.i(HOM25_TAG, "extractText text_200p all pages (API ${android.os.Build.VERSION.SDK_INT}): %.0f ms".format(ms))
        assertEquals(200, r.documentPageCount)
        assertEquals(200, r.pages.size)
        assertFalse(r.truncated)
        r.pages.forEachIndexed { i, p ->
            assertEquals(i, p.pageIndex)
            assertTrue("page $i token", p.text.contains(token("HOM27T", i)))
            assertFalse("page $i has another page's token", p.text.contains(token("HOM27T", (i + 1) % 200)))
        }
    }

    @Test
    fun rotatedPageTextIsExtracted() {
        val r = PdfTextExtraction.extract(Fixtures.path(Fixtures.MERGE_3), null, 0, -1, -1)
        assertEquals(3, r.pages.size)
        for (i in 0 until 3) assertTrue("merge partner page $i token", r.pages[i].text.contains(token("HOM27M", i)))
        // What plain PDFTextStripper (no rotation handling) finds, for the record (HOM-27 saw 2/3).
        val plain = PDDocument.load(Fixtures.file(Fixtures.MERGE_3)).use { doc ->
            (0 until 3).count { i -> PDFTextStripper().apply { startPage = i + 1; endPage = i + 1 }.getText(doc).contains(token("HOM27M", i)) }
        }
        Log.i(HOM25_TAG, "plain PDFTextStripper on merge_partner_3p: $plain/3 tokens; HOM-25 reader: 3/3")
    }

    @Test
    fun pdfBoxReaderHandlesRotationOnEveryApiLevel() {
        // The reader used before API 35 (and for pages the platform fails on), tested on every level.
        PDDocument.load(Fixtures.file(Fixtures.MERGE_3)).use { doc ->
            val reader = PdfBoxTextReader(doc)
            val pages = ArrayList<PageText>()
            reader.read(0, 3, boxes = true, isCancelled = { false }) { pages += it; true }
            for (i in 0 until 3) assertTrue("PdfBox page $i token", pages[i].text.contains(token("HOM27M", i)))
            // Bounds of the token on the rotated page are in the unrotated page space, like page 1's.
            val b3 = pages[2].let { p -> p.text.indexOf("HOM27M-P0003").let { p.bounds(it, it + 12)!! } }
            val b1 = pages[0].let { p -> p.text.indexOf("HOM27M-P0001").let { p.bounds(it, it + 12)!! } }
            assertEquals(b1[0], b3[0], 1f)
            assertEquals(b1[1], b3[1], 1f)
            assertTrue("x ${b1[0]}", b1[0] in 70f..120f)
            assertTrue("y ${b1[1]}", b1[1] in 735f..760f)
        }
        PDDocument.load(Fixtures.file(Fixtures.TEXT_200)).use { doc ->
            val t0 = System.nanoTime()
            val r = PdfTextExtraction.extract(PdfBoxTextReader(doc), 0, -1, -1)
            Log.i(HOM25_TAG, "PdfBox extractText text_200p all pages: %.0f ms".format((System.nanoTime() - t0) / 1e6))
            assertEquals(200, r.pages.size)
            r.pages.forEachIndexed { i, p -> assertTrue(p.text.contains(token("HOM27T", i))) }
        }
    }

    @Test
    fun annotatedAndImageOnlyFiles() {
        val a = PdfTextExtraction.extract(Fixtures.path(Fixtures.ANNOTATED_2), null, 0, -1, -1)
        assertTrue(a.pages[0].text.contains("HOM27A-P0001"))
        assertTrue(a.pages[1].text.contains("HOM27A-P0002"))
        val img = PdfTextExtraction.extract(Fixtures.path(Fixtures.IMAGES_2), null, 0, -1, -1)
        assertEquals(2, img.pages.size)
        assertTrue(img.pages.all { it.text.isBlank() })
    }

    @Test
    fun rangesAndLimits() {
        val path = Fixtures.path(Fixtures.TEXT_200)
        val mid = PdfTextExtraction.extract(path, null, 10, 5, -1)
        assertEquals((10..14).toList(), mid.pages.map { it.pageIndex })
        assertTrue(mid.pages[0].text.contains("HOM27T-P0011"))
        assertEquals(listOf(198, 199), PdfTextExtraction.extract(path, null, 198, -1, -1).pages.map { it.pageIndex })
        assertEquals(listOf(199), PdfTextExtraction.extract(path, null, 199, 50, -1).pages.map { it.pageIndex })
        val past = PdfTextExtraction.extract(path, null, 500, -1, -1)
        assertEquals(200, past.documentPageCount)
        assertTrue(past.pages.isEmpty())
        assertTrue(PdfTextExtraction.extract(path, null, 0, 0, -1).pages.isEmpty())

        val limited = PdfTextExtraction.extract(path, null, 0, -1, 100)
        assertTrue(limited.truncated)
        assertEquals(100, limited.pages.sumOf { it.text.length })
        assertEquals(1, limited.pages.size)
        val exact = PdfTextExtraction.extract(path, null, 0, 1, -1).pages[0].text.length
        val fits = PdfTextExtraction.extract(path, null, 0, 1, exact)
        assertFalse(fits.truncated)
        val zero = PdfTextExtraction.extract(path, null, 0, -1, 0)
        assertTrue(zero.truncated)
        assertEquals("", zero.pages.single().text)

        assertEquals(PdfErrorCode.invalidArgument, code { PdfTextExtraction.extract(path, null, -1, -1, -1) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfTextExtraction.extract(path, null, 0, -2, -1) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfTextExtraction.extract(path, null, 0, -1, -2) })
    }

    @Test
    fun passwordsAndDamagedFiles() {
        val enc = Fixtures.encrypted.absolutePath
        assertEquals(PdfErrorCode.passwordRequired, code { PdfTextExtraction.extract(enc, null, 0, -1, -1) })
        assertEquals(PdfErrorCode.passwordRequired, code { PdfTextExtraction.extract(enc, "wrong", 0, -1, -1) })
        val r = PdfTextExtraction.extract(enc, Fixtures.USER_PASSWORD, 0, -1, -1)
        for (i in 0 until 3) assertTrue(r.pages[i].text.contains(token("HOM27M", i)))
        // Owner-only encryption: readable without a password (the index ignores copy permissions, as on Apple).
        assertTrue(PdfTextExtraction.extract(Fixtures.restricted.absolutePath, null, 0, 1, -1).pages[0].text.contains("HOM27M-P0001"))

        for (kind in Fixtures.damagedKinds) {
            try {
                val t = PdfTextExtraction.extract(Fixtures.damaged(kind).absolutePath, null, 0, -1, -1)
                assertEquals("extract $kind", "truncated", kind) // PdfBox may repair a truncated file.
                assertTrue(t.documentPageCount >= 0)
            } catch (f: PdfFailure) {
                assertEquals("extract $kind", PdfErrorCode.damaged, f.code)
            }
        }
        assertEquals(PdfErrorCode.notFound, code { PdfTextExtraction.extract(Fixtures.missing, null, 0, -1, -1) })
    }

    @Test
    fun hostApiExtractsOffTheMainThread() {
        val threads = PdfThreads()
        try {
            val api = PdfTextHostApiImpl(threads)
            val r = awaitCall<PdfTextResultMsg> { api.extractText(PdfTextRequestMsg(Fixtures.path(Fixtures.MERGE_3), null, 2, 1, -1), it) }.getOrThrow()
            assertEquals(3L, r.documentPageCount)
            assertEquals(2L, r.pages.single().pageIndex)
            assertTrue(r.pages.single().text.contains("HOM27M-P0003"))
            assertCode("passwordRequired", awaitCall<PdfTextResultMsg> { api.extractText(PdfTextRequestMsg(Fixtures.encrypted.absolutePath, null, 0, -1, -1), it) })
            assertCode("damaged", awaitCall<PdfTextResultMsg> { api.extractText(PdfTextRequestMsg(Fixtures.damaged("png").absolutePath, null, 0, -1, -1), it) })
            assertCode("invalidArgument", awaitCall<PdfTextResultMsg> { api.extractText(PdfTextRequestMsg(Fixtures.path(Fixtures.MERGE_3), null, -3, -1, -1), it) })
        } finally {
            threads.shutdown()
        }
    }

    // ---- search ----

    private fun open(path: String): OpenPdf = store.get(store.open(path, null).handle)

    @Test
    fun searchFindsTokensWithBoundsInPageSpace() {
        val doc = open(Fixtures.path(Fixtures.TEXT_200))
        val t0 = System.nanoTime()
        val r = PdfSearch.search(doc, "hom27t-p0150", caseSensitive = false, maxHits = 50, token = PdfCancelToken())
        Log.i(HOM25_TAG, "search text_200p (first, uncached): %.0f ms".format((System.nanoTime() - t0) / 1e6))
        val hit = r.hits.single()
        assertFalse(r.truncated)
        assertEquals(149, hit.match.pageIndex)
        assertEquals(12, hit.match.length)
        val page = PdfTextExtraction.extract(Fixtures.path(Fixtures.TEXT_200), null, 149, 1, -1).pages.single().text
        assertEquals("HOM27T-P0150", page.substring(hit.match.start, hit.match.start + hit.match.length))
        assertEquals("HOM27T-P0150", hit.match.snippet.substring(hit.match.snippetMatchStart, hit.match.snippetMatchStart + 12))
        // The token line: 11 pt Helvetica, baseline at y = 842 - 96 = 746, starting after "Token " at x = 56.
        val (x, y, w, h) = hit.bounds.toList()
        assertTrue("x $x", x in 70f..120f)
        assertTrue("y $y", y in 735f..760f)
        assertTrue("w $w", w in 50f..110f)
        assertTrue("h $h", h in 4f..16f)

        val t1 = System.nanoTime()
        PdfSearch.search(doc, "HOM27T-P0151", caseSensitive = true, maxHits = 50, token = PdfCancelToken())
        Log.i(HOM25_TAG, "search text_200p (cached text): %.0f ms".format((System.nanoTime() - t1) / 1e6))
        assertTrue(PdfSearch.search(doc, "hom27t-p0150", caseSensitive = true, maxHits = 50, token = PdfCancelToken()).hits.isEmpty())
    }

    @Test
    fun searchOnTheRotatedPageReportsUnrotatedBounds() {
        val doc = open(Fixtures.path(Fixtures.MERGE_3))
        val hit = PdfSearch.search(doc, "HOM27M-P0003", false, 10, PdfCancelToken()).hits.single()
        assertEquals(2, hit.match.pageIndex)
        // Page space is the unrotated crop box: the token sits where it does on the portrait page 1.
        val first = PdfSearch.search(doc, "HOM27M-P0001", false, 10, PdfCancelToken()).hits.single()
        assertEquals(first.bounds[0], hit.bounds[0], 1f)
        assertEquals(first.bounds[1], hit.bounds[1], 1f)
        assertTrue(hit.bounds[2] > 30f)
    }

    @Test
    fun searchLimitsAndCancels() {
        val doc = open(Fixtures.path(Fixtures.TEXT_200))
        val many = PdfSearch.search(doc, "HOM27T", false, 10, PdfCancelToken())
        assertEquals(10, many.hits.size)
        assertTrue(many.truncated)
        assertEquals((0 until 10).toList(), many.hits.map { it.match.pageIndex })
        val all = PdfSearch.search(doc, "HOM27T-P", false, 500, PdfCancelToken())
        assertEquals(200, all.hits.size)
        assertFalse(all.truncated)
        assertTrue(PdfSearch.search(doc, "  ", false, 10, PdfCancelToken()).hits.isEmpty())
        assertTrue(PdfSearch.search(doc, "HOM27T", false, 0, PdfCancelToken()).hits.isEmpty())
        assertTrue(PdfSearch.search(doc, "no such words here", false, 10, PdfCancelToken()).hits.isEmpty())
        val cancelled = PdfCancelToken().apply { cancel() }
        assertEquals(PdfErrorCode.cancelled, code { PdfSearch.search(doc, "HOM27T", false, 10, cancelled) })
    }

    @Test
    fun searchOfALockedDocumentNeedsThePassword() {
        val locked = store.get(store.open(Fixtures.encrypted.absolutePath, null).handle)
        assertEquals(PdfErrorCode.passwordRequired, code { PdfSearch.search(locked, "HOM27M", false, 10, PdfCancelToken()) })
    }
}
