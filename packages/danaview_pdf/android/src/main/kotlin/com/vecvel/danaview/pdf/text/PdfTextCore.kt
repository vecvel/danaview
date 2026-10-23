// OWNER: HOM-25
//
// The Flutter-free text core on Android (ARCH v1.2 §8 "PDF text (search)"), over PdfBoxText.kt:
//
// - [PdfTextExtraction.extract]: the text of a page range of a file for the search index (AIS-50's
//   DocumentTextPort), from its own read-only open; the same range, limit and truncation rules as
//   HOM-24's PdfTextExtractor.
// - [PdfSearch.search]: in-document search over an open document's text source, page by page so a
//   newer search or cancelSearch stops an older one between pages. Page texts are cached per
//   document for the next query (bounded, PageTextCache) and filled ahead by the pre-warm below API
//   35 (PdfTextPrewarm.kt); hit bounds are read only for pages with hits.
// - [TextSources]: the platform text layer from API 35, PdfBox before (PageTextSource.kt).
// Nothing here logs document text or queries (rule 30).

package com.vecvel.danaview.pdf.text

import android.annotation.SuppressLint
import android.os.Build
import androidx.annotation.ChecksSdkIntAtLeast
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.viewer.OpenPdf
import com.vecvel.danaview.pdf.viewer.PageGeometry
import com.vecvel.danaview.pdf.viewer.PlatformPdf
import java.io.Closeable
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.withLock

/** A cancel flag shared between the main thread and background work. */
class PdfCancelToken {
    private val flag = AtomicBoolean(false)
    val isCancelled: Boolean get() = flag.get()

    fun cancel() = flag.set(true)
}

/** Extracted text of a page range. */
data class PdfTextExtractionResult(val documentPageCount: Int, val pages: List<PageText>, val truncated: Boolean)

object PdfTextExtraction {
    /**
     * Text of [pageCount] pages (-1: to the end) from [firstPage] of the file at [path], opened
     * read-only; stops after [maxChars] UTF-16 units in total (-1: no limit).
     */
    fun extract(path: String, password: String?, firstPage: Int, pageCount: Int, maxChars: Int, isCancelled: () -> Boolean = { false }): PdfTextExtractionResult {
        if (firstPage < 0 || pageCount < -1 || maxChars < -1) throw PdfFailure.invalid("bad page range")
        val file = PlatformPdf.checkFile(path)
        TextSources.forFile(file, password).use { source ->
            return extract(source.source, firstPage, pageCount, maxChars, isCancelled)
        }
    }

    fun extract(source: PageTextSource, firstPage: Int, pageCount: Int, maxChars: Int, isCancelled: () -> Boolean = { false }): PdfTextExtractionResult {
        if (firstPage < 0 || pageCount < -1 || maxChars < -1) throw PdfFailure.invalid("bad page range")
        val total = source.pageCount
        val end = if (pageCount < 0) total else minOf(total, firstPage + pageCount)
        val budget = TextBudget(maxChars)
        val pages = ArrayList<PageText>()
        if (firstPage < end) {
            source.read(firstPage, end, boxes = false, isCancelled = isCancelled) { page ->
                pages += PageText(page.pageIndex, budget.take(page.text))
                !budget.truncated
            }
        }
        return PdfTextExtractionResult(total, pages, budget.truncated)
    }
}

/** Chooses the text source of a file or an open document (PageTextSource.kt). */
object TextSources {
    /** Whether this device reads text with the platform (API 35+). */
    @get:ChecksSdkIntAtLeast(api = Build.VERSION_CODES.VANILLA_ICE_CREAM)
    val platformText: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM

    /** A source over the file at [file] and what to close after it. */
    class Opened(val source: PageTextSource, private val closeables: List<Closeable>) : Closeable {
        override fun close() = closeables.forEach {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * The text of [file] opened read-only with [password]: the platform from API 35 (PdfBox for
     * pages it fails on), else PdfBox. `passwordRequired` / `damaged` / `notFound` as the opens say.
     */
    fun forFile(file: File, password: String?): Opened {
        if (platformText) {
            val platform = try {
                PlatformPdf.open(file, password)
            } catch (f: PdfFailure) {
                if (f.code != PdfErrorCode.damaged) throw f
                null // PdfBox may still read what PDFium refuses.
            }
            if (platform != null) {
                val lazy = LazyPdfBox(file, password)
                return Opened(platformSource(platform, null, lazy), listOf(platform, lazy))
            }
        }
        val document = PdfBoxSupport.load(file, password)
        return Opened(PdfBoxTextReader(document), listOf(document))
    }

    /** The text of an open, unlocked document (call under its textLock). */
    fun forDocument(doc: OpenPdf): PageTextSource {
        val platform = doc.requirePlatform()
        val pdfBox = doc.text?.let { PdfBoxTextReader(it) }
        if (platformText) return platformSource(platform, doc.pages, pdfBox)
        return pdfBox ?: throw PdfFailure(PdfErrorCode.unsupported, "no text reader for this file")
    }

    @SuppressLint("NewApi") // Called only when platformText (API 35+).
    private fun platformSource(platform: PlatformPdf, pages: List<PageGeometry>?, fallback: PageTextSource?): PageTextSource {
        val geometry = pages ?: List(platform.pageCount) { i ->
            val (w, h) = platform.pageSize(i)
            PageGeometry.reconcile(null, w, h)
        }
        return PlatformTextSource(platform, geometry, fallback)
    }

    /** A PdfBox reader of [file] loaded on first use (pages the platform can't read). */
    private class LazyPdfBox(private val file: File, private val password: String?) : PageTextSource, Closeable {
        private var document: PDDocument? = null
        private var failed = false

        private fun reader(): PageTextSource? {
            if (failed) return null
            val d = document ?: try {
                PdfBoxSupport.load(file, password).also { document = it }
            } catch (f: PdfFailure) {
                failed = true
                return null
            }
            return PdfBoxTextReader(d)
        }

        override val pageCount: Int get() = reader()?.pageCount ?: 0

        override fun read(first: Int, end: Int, boxes: Boolean, isCancelled: () -> Boolean, onPage: (PageText) -> Boolean) {
            reader()?.read(first, end, boxes, isCancelled, onPage)
        }

        override fun page(index: Int, boxes: Boolean): PageText = reader()?.page(index, boxes) ?: PageText(index, "")

        override fun close() {
            try {
                document?.close()
            } catch (_: Exception) {
            }
        }
    }
}

/** One search hit with its bounds in page space (x, y, width, height; zeros when unknown). */
data class PdfSearchHit(val match: TextMatch, val bounds: FloatArray)

/** The hits of one search. */
data class PdfSearchOutcome(val hits: List<PdfSearchHit>, val truncated: Boolean)

object PdfSearch {
    /** Cached page text per document, in UTF-16 units (beyond it pages are re-read per search). */
    const val CACHE_CHARS = 8_000_000L

    /** Finds [query] in [doc] page by page (off the main thread). */
    fun search(doc: OpenPdf, query: String, caseSensitive: Boolean, maxHits: Int, token: PdfCancelToken): PdfSearchOutcome {
        val q = TextQuery.of(query, caseSensitive)
        if (q.isEmpty || maxHits <= 0) return PdfSearchOutcome(emptyList(), false)
        doc.requirePlatform()
        return doc.textLock.withLock {
            val reader = TextSources.forDocument(doc)
            val n = reader.pageCount
            // Pages the pre-warm (PdfTextPrewarm.kt) or an earlier search cached are not read again.
            val cache = cacheOf(doc, n)
            val matches = ArrayList<TextMatch>()
            var truncated = false
            var page = 0
            while (page < n && !truncated) {
                if (token.isCancelled) throw PdfFailure.cancelled()
                val cached = cache.get(page)
                if (cached != null) {
                    truncated = collect(q, page, cached, maxHits, matches)
                    page++
                    continue
                }
                // Read a window of uncached pages (up to the next cached one), caching their text.
                val until = cache.nextCached(page, minOf(n, page + 8))
                reader.read(page, until, boxes = false, isCancelled = { token.isCancelled }) { p ->
                    cache.put(p.pageIndex, p.text)
                    truncated = collect(q, p.pageIndex, p.text, maxHits, matches)
                    !truncated
                }
                page = until
            }
            // Glyph boxes, once per page with hits.
            val hits = ArrayList<PdfSearchHit>(matches.size)
            var boxed: PageText? = null
            for (m in matches) {
                if (token.isCancelled) throw PdfFailure.cancelled()
                if (boxed?.pageIndex != m.pageIndex) boxed = reader.page(m.pageIndex, boxes = true)
                val b = boxed.takeIf { it.text.length >= m.start + m.length }?.bounds(m.start, m.start + m.length)
                hits += PdfSearchHit(m, b ?: FloatArray(4))
            }
            PdfSearchOutcome(hits, truncated)
        }
    }

    /** [doc]'s page-text cache for [pageCount] pages (call under its textLock). */
    internal fun cacheOf(doc: OpenPdf, pageCount: Int): PageTextCache =
        doc.textCache?.takeIf { it.pageCount == pageCount } ?: PageTextCache(pageCount, CACHE_CHARS).also { doc.textCache = it }

    /** Adds [text]'s matches up to [maxHits]; true when more exist (truncated). */
    private fun collect(q: TextQuery, pageIndex: Int, text: String, maxHits: Int, into: MutableList<TextMatch>): Boolean {
        val room = maxHits - into.size
        val found = q.matches(pageIndex, text, room + 1)
        if (found.size > room) {
            into += found.take(room)
            return true
        }
        into += found
        return false
    }
}

/**
 * Page texts of one document by index, up to [budget] UTF-16 units in total (beyond it pages are
 * read per search). Not thread-safe: the owner's textLock guards it.
 */
class PageTextCache(val pageCount: Int, private val budget: Long) {
    private val pages = arrayOfNulls<String>(maxOf(0, pageCount))

    /** UTF-16 units cached. */
    var chars = 0L
        private set

    var cachedPages = 0
        private set

    /** True once a page didn't fit the budget. */
    var isFull = false
        private set

    fun get(index: Int): String? = pages.getOrNull(index)

    /** Caches [text] as page [index]; false when it is out of range or doesn't fit. */
    fun put(index: Int, text: String): Boolean {
        if (index !in pages.indices) return false
        if (pages[index] != null) return true
        if (chars + text.length > budget) {
            isFull = true
            return false
        }
        pages[index] = text
        chars += text.length
        cachedPages++
        return true
    }

    /** The first uncached page at or after [from], or -1. */
    fun firstMissing(from: Int): Int {
        for (i in maxOf(0, from) until pages.size) if (pages[i] == null) return i
        return -1
    }

    /** The first cached page in `[from, until)`, or [until]. */
    fun nextCached(from: Int, until: Int): Int {
        for (i in maxOf(0, from) until minOf(until, pages.size)) if (pages[i] != null) return i
        return until
    }
}
