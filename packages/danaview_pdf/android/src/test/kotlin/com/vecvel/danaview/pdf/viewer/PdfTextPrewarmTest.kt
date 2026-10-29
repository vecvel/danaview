// OWNER: HOM-25
//
// JVM tests of the page-text pre-warm below API 35 (text/PdfTextPrewarm.kt, lead 9d15fe3e answer 3)
// and the cache it shares with search (text/PdfTextCore.kt PageTextCache): the policy (API level,
// 500-page cut-off), one job per document, page-by-page progress a search can use, cancel between
// pages, failures, and the thread exiting when idle. A fake target stands in for an open document:
// the same fair lock, cache and one-page-per-hold reads as OpenPdfPrewarmTarget.

package com.vecvel.danaview.pdf.viewer

import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.text.PageTextCache
import com.vecvel.danaview.pdf.text.PrewarmTarget
import com.vecvel.danaview.pdf.text.TextPrewarmJob
import com.vecvel.danaview.pdf.text.TextPrewarmPolicy
import com.vecvel.danaview.pdf.text.TextPrewarmer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** DV_PERF_STRICT=1 (environment or system property): absolute timing limits apply (a quiet machine). */
private val perfStrict = System.getenv("DV_PERF_STRICT") == "1" || System.getProperty("DV_PERF_STRICT") == "1"

class PdfTextPrewarmTest {
    /** A document of [pages] pages whose page read takes [pageMs]. */
    private class FakeDoc(val pages: Int, private val pageMs: Long = 0, budget: Long = Long.MAX_VALUE) : PrewarmTarget {
        val lock = ReentrantLock(true)
        val cache = PageTextCache(pages, budget)
        val reads = AtomicInteger()
        @Volatile var closed = false
        @Volatile var failAt = -1
        var gate: CountDownLatch? = null

        fun text(i: Int) = "page-$i "

        private fun read(i: Int): String {
            if (i == failAt) throw PdfFailure.damaged("page text can't be read")
            gate?.await(5, TimeUnit.SECONDS)
            if (pageMs > 0) Thread.sleep(pageMs)
            reads.incrementAndGet()
            return text(i)
        }

        override fun warmNext(from: Int): Int = lock.withLock {
            if (closed || cache.isFull) return -1
            val page = cache.firstMissing(from)
            if (page < 0) return -1
            if (!cache.put(page, read(page))) return -1
            page
        }

        /** What PdfSearch.search does: cached pages as they are, the rest read and cached. */
        fun searchAll(): List<String> = lock.withLock {
            (0 until pages).map { i -> cache.get(i) ?: read(i).also { cache.put(i, it) } }
        }
    }

    private fun await(timeoutMs: Long = 5_000, what: String, test: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (test()) return
            Thread.sleep(2)
        }
        throw AssertionError("timed out: $what")
    }

    // ---- policy ----

    @Test
    fun policyPrewarmsOnlyBelowApi35UpTo500PagesWithPdfBox() {
        assertTrue(TextPrewarmPolicy.shouldPrewarm(28, 200, true))
        assertTrue(TextPrewarmPolicy.shouldPrewarm(34, 1, true))
        assertTrue(TextPrewarmPolicy.shouldPrewarm(24, 500, true))
        assertFalse("over 500 pages stays on demand", TextPrewarmPolicy.shouldPrewarm(29, 501, true))
        assertFalse("platform text from 35", TextPrewarmPolicy.shouldPrewarm(35, 200, true))
        assertFalse(TextPrewarmPolicy.shouldPrewarm(37, 3, true))
        assertFalse("no PdfBox document", TextPrewarmPolicy.shouldPrewarm(28, 200, false))
        assertFalse(TextPrewarmPolicy.shouldPrewarm(28, 0, true))
    }

    // ---- cache ----

    @Test
    fun cacheKeepsPagesWithinItsBudget() {
        val c = PageTextCache(5, budget = 10)
        assertTrue(c.put(0, "abcd"))
        assertTrue(c.put(2, "efgh"))
        assertTrue("an already cached page is kept", c.put(2, "zzzzzzzz"))
        assertEquals("efgh", c.get(2))
        assertFalse(c.isFull)
        assertFalse("over the budget", c.put(3, "ijk"))
        assertTrue(c.isFull)
        assertNull(c.get(3))
        assertFalse("out of range", c.put(7, "x"))
        assertEquals(2, c.cachedPages)
        assertEquals(8L, c.chars)
        assertEquals(1, c.firstMissing(0))
        assertEquals(3, c.firstMissing(2))
        assertEquals(2, c.nextCached(1, 5))
        assertEquals(4, c.nextCached(3, 4))
        val full = PageTextCache(2, 100).apply { put(0, "a"); put(1, "b") }
        assertEquals(-1, full.firstMissing(0))
    }

    // ---- jobs ----

    @Test
    fun jobCachesEveryPageInOrderThenStops() {
        val doc = FakeDoc(30)
        val job = TextPrewarmJob(doc)
        job.run()
        assertEquals(TextPrewarmJob.State.DONE, job.state)
        assertEquals(30, job.pagesWarmed)
        assertEquals(30, doc.cache.cachedPages)
        assertEquals((0 until 30).map(doc::text), (0 until 30).map { doc.cache.get(it) })
    }

    @Test
    fun jobSkipsPagesASearchAlreadyCachedAndStopsWhenTheCacheIsFull() {
        val doc = FakeDoc(10)
        (0 until 10 step 2).forEach { doc.cache.put(it, doc.text(it)) }
        TextPrewarmJob(doc).run()
        assertEquals("only the 5 missing pages are read", 5, doc.reads.get())

        val small = FakeDoc(10, budget = 3L * "page-0 ".length)
        val job = TextPrewarmJob(small).also { it.run() }
        assertEquals(TextPrewarmJob.State.DONE, job.state)
        assertEquals(3, small.cache.cachedPages)
        assertTrue(small.cache.isFull)
    }

    @Test
    fun jobEndsQuietlyOnClosedDocumentsAndUnreadablePages() {
        val closed = FakeDoc(5).apply { closed = true }
        TextPrewarmJob(closed).also { it.run() }.let {
            assertEquals(TextPrewarmJob.State.DONE, it.state)
            assertEquals(0, it.pagesWarmed)
        }
        val bad = FakeDoc(5).apply { failAt = 3 }
        TextPrewarmJob(bad).also { it.run() }.let {
            assertEquals(TextPrewarmJob.State.FAILED, it.state)
            assertEquals(3, it.pagesWarmed)
        }
    }

    @Test
    fun cancelledJobNeverStartsAndARunningOneStopsBeforeItsNextPage() {
        val queued = TextPrewarmJob(FakeDoc(5)).apply { cancel() }
        queued.run()
        assertEquals(TextPrewarmJob.State.CANCELLED, queued.state)
        assertEquals(0, queued.pagesWarmed)

        val prewarmer = TextPrewarmer(keepAliveMs = 100)
        val doc = FakeDoc(200, pageMs = 5)
        assertTrue(prewarmer.schedule(1, doc))
        val job = prewarmer.job(1)!!
        await(what = "some pages warmed") { job.pagesWarmed >= 3 }
        prewarmer.cancel(1)
        await(what = "job stopped") { job.isFinished }
        assertEquals(TextPrewarmJob.State.CANCELLED, job.state)
        val warmed = doc.cache.cachedPages
        assertTrue("stopped early: $warmed pages", warmed < 200)
        Thread.sleep(50)
        assertEquals("nothing read after the cancel", warmed, doc.cache.cachedPages)
        assertNull(prewarmer.job(1))
        await(what = "thread exits when idle") { prewarmer.threadCount == 0 }
        prewarmer.shutdown()
    }

    // ---- scheduling ----

    @Test
    fun oneJobPerDocumentAndJobsRunOneAtATime() {
        val prewarmer = TextPrewarmer(keepAliveMs = 100)
        val a = FakeDoc(20, pageMs = 1)
        val b = FakeDoc(20, pageMs = 1)
        assertTrue(prewarmer.schedule(1, a))
        assertFalse("a second view of the same document", prewarmer.schedule(1, a))
        assertTrue(prewarmer.schedule(2, b))
        assertTrue(prewarmer.threadCount <= 1)
        await(what = "both done") { prewarmer.job(1)!!.isFinished && prewarmer.job(2)!!.isFinished }
        assertEquals(20, a.reads.get())
        assertEquals(20, b.reads.get())
        assertFalse("still once per document after it finished", prewarmer.schedule(1, a))
        await(what = "thread exits when idle") { prewarmer.threadCount == 0 }
        prewarmer.shutdown()
        assertFalse("rejected after shutdown", prewarmer.schedule(3, FakeDoc(1)))
        assertNull(prewarmer.job(3))
    }

    @Test
    fun searchDuringThePrewarmUsesItsPagesAndReadsOnlyTheRest() {
        val prewarmer = TextPrewarmer(keepAliveMs = 100)
        val doc = FakeDoc(100, pageMs = 3)
        prewarmer.schedule(1, doc)
        val job = prewarmer.job(1)!!
        await(what = "a third warmed") { job.pagesWarmed >= 30 }
        val texts = doc.searchAll()
        assertEquals((0 until 100).map(doc::text), texts)
        await(what = "job done") { job.isFinished }
        assertEquals(TextPrewarmJob.State.DONE, job.state)
        assertEquals("every page read exactly once by the two together", 100, doc.reads.get())
        prewarmer.shutdown()
    }

    @Test
    fun aWaitingSearchGetsTheLockAfterOnePage() {
        val prewarmer = TextPrewarmer(keepAliveMs = 100)
        val doc = FakeDoc(400, pageMs = 20)
        prewarmer.schedule(1, doc)
        val job = prewarmer.job(1)!!
        await(what = "started") { job.pagesWarmed >= 1 }
        val t0 = System.nanoTime()
        val got = doc.lock.withLock { doc.cache.cachedPages }
        val waitedMs = (System.nanoTime() - t0) / 1e6
        // One 20 ms page, not the 8 s of all 400: 200 ms with DV_PERF_STRICT=1, 2 s on a loaded
        // CI host (still far below the whole document).
        val bound = if (perfStrict) 200.0 else 2_000.0
        assertTrue("waited $waitedMs ms (bound $bound)", waitedMs < bound)
        assertTrue(got in 1 until 400)
        prewarmer.shutdown()
        await(what = "stopped by shutdown") { job.isFinished }
    }
}
