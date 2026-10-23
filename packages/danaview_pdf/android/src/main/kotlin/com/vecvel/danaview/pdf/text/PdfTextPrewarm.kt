// OWNER: HOM-25
//
// Background pre-warm of the page-text cache below API 35 (lead 9d15fe3e, answer 3). PdfBox reads
// about 35-40 ms a page on API 28/29, so a first search of a 200-page file would wait 7-8 s; the
// platform text from API 35 is fast enough to stay on demand.
//
// - When: after a document's first full-quality frame is on screen (PdfTextureView
//   `onFirstCompleteFrame`), once per document; later views of the same document don't restart it.
// - Which: [TextPrewarmPolicy]: API < 35, a PdfBox document, 1..500 pages. Larger files stay on
//   demand (their text would also crowd the cache budget).
// - How: one low-priority background thread ([TextPrewarmer]; it exits after a second idle), page
//   by page into the same per-document cache search uses ([PageTextCache], guarded by the
//   document's fair textLock). The lock is held for one page at a time, so a search started meanwhile
//   gets it after at most one page, uses every page already cached and reads only the rest itself;
//   the pre-warm then resumes where the cache says.
// - Stop: closing the document cancels its job between pages (PdfDocumentHostApiImpl.close), and a
//   closed document or a full cache ends it too; detach cancels everything.
// Nothing here logs document text (rule 30).

package com.vecvel.danaview.pdf.text

import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.viewer.OpenPdf
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.withLock

/** Whether a document's text is pre-warmed. */
object TextPrewarmPolicy {
    /** First API level whose platform text makes the pre-warm unnecessary (Android 15). */
    const val PLATFORM_TEXT_API = 35

    /** Larger documents keep their text on demand (lead: "over about 500 pages"). */
    const val MAX_PAGES = 500

    fun shouldPrewarm(sdkInt: Int, pageCount: Int, hasPdfBoxText: Boolean): Boolean =
        sdkInt < PLATFORM_TEXT_API && hasPdfBoxText && pageCount in 1..MAX_PAGES
}

/** What a pre-warm job fills ([OpenPdf] in the app; fakes in the JVM tests). */
interface PrewarmTarget {
    /**
     * Reads and caches the first uncached page at or after [from] under the document's text lock and
     * returns its index; -1 when nothing is left (every page cached, the cache full, the document
     * closed or unreadable).
     */
    fun warmNext(from: Int): Int
}

/** One document's pre-warm: page after page until done or cancelled. */
class TextPrewarmJob(private val target: PrewarmTarget) : Runnable {
    enum class State { QUEUED, RUNNING, DONE, CANCELLED, FAILED }

    private val token = PdfCancelToken()

    @Volatile var state: State = State.QUEUED
        private set

    /** Pages this job read and cached. */
    @Volatile var pagesWarmed: Int = 0
        private set

    val isCancelled: Boolean get() = token.isCancelled

    val isFinished: Boolean get() = state == State.DONE || state == State.CANCELLED || state == State.FAILED

    fun cancel() {
        token.cancel()
        // A job still in the queue never starts.
        if (state == State.QUEUED) state = State.CANCELLED
    }

    override fun run() {
        if (token.isCancelled) {
            state = State.CANCELLED
            return
        }
        state = State.RUNNING
        var from = 0
        try {
            while (true) {
                if (token.isCancelled || Thread.currentThread().isInterrupted) {
                    state = State.CANCELLED
                    return
                }
                val page = target.warmNext(from)
                if (page < 0) break
                pagesWarmed++
                from = page + 1
            }
            state = if (token.isCancelled) State.CANCELLED else State.DONE
        } catch (f: PdfFailure) {
            // Closed meanwhile, or a page PdfBox can't read: search reads on demand as before.
            state = if (token.isCancelled) State.CANCELLED else State.FAILED
        } catch (e: Exception) {
            // InterruptedException from a shutdown, or anything PdfBox throws.
            state = if (token.isCancelled || e is InterruptedException) State.CANCELLED else State.FAILED
        } catch (e: OutOfMemoryError) {
            state = State.FAILED
        }
    }
}

/**
 * Runs pre-warm jobs on one background thread, at most one job per document key. The thread is
 * created on demand and exits after [keepAliveMs] idle, so no thread outlives the work.
 */
class TextPrewarmer(keepAliveMs: Long = 1_000, threadSetup: () -> Unit = {}) {
    private val jobs = ConcurrentHashMap<Long, TextPrewarmJob>()

    private val executor = ThreadPoolExecutor(1, 1, keepAliveMs, TimeUnit.MILLISECONDS, LinkedBlockingQueue()) { r ->
        Thread({
            threadSetup()
            r.run()
        }, THREAD_NAME).apply {
            priority = Thread.MIN_PRIORITY
            isDaemon = true
        }
    }.apply { allowCoreThreadTimeOut(true) }

    /** Live pre-warm threads (0 or 1; tests). */
    val threadCount: Int get() = executor.poolSize

    /** The job of [key], if one was scheduled and not cancelled (tests). */
    fun job(key: Long): TextPrewarmJob? = jobs[key]

    /** Queues a pre-warm of [target] under [key] unless one exists; true when queued now. */
    fun schedule(key: Long, target: PrewarmTarget): Boolean {
        val job = TextPrewarmJob(target)
        if (jobs.putIfAbsent(key, job) != null) return false
        return try {
            executor.execute(job)
            true
        } catch (e: RejectedExecutionException) {
            jobs.remove(key, job)
            false
        }
    }

    /** Cancels and forgets [key]'s job (the document closed); it stops before its next page. */
    fun cancel(key: Long) {
        jobs.remove(key)?.cancel()
    }

    fun cancelAll() {
        jobs.keys.toList().forEach(::cancel)
    }

    /** Cancels everything and stops the thread (plugin detached). */
    fun shutdown() {
        cancelAll()
        executor.shutdownNow()
    }

    companion object {
        const val THREAD_NAME = "danaview-pdf-prewarm"
    }
}

/** The pre-warm of an open document: one page per hold of its textLock. */
class OpenPdfPrewarmTarget(private val doc: OpenPdf) : PrewarmTarget {
    override fun warmNext(from: Int): Int = doc.textLock.withLock {
        if (doc.closed || doc.text == null) return -1
        val reader = TextSources.forDocument(doc)
        val cache = PdfSearch.cacheOf(doc, reader.pageCount)
        if (cache.isFull) return -1
        val page = cache.firstMissing(from)
        if (page < 0) return -1
        if (!cache.put(page, reader.page(page, boxes = false).text)) return -1
        page
    }
}
