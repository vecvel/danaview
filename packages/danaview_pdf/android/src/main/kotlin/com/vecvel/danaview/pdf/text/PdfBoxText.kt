// OWNER: HOM-25
//
// The PdfBox-Android text layer (PageTextSource.kt): every page's text before API 35, files the
// platform renderer can't open, and pages the platform fails on. PdfBox-Android 2.0.27.0 is the
// accepted Android PDF engine (HOM-27 / D-98j), used read-only here.
//
// - Files are opened read-only (`PDDocument.load(File)` reads, never writes; rule 27); the
//   in-memory documents are never saved.
// - /Rotate: PDFTextStripper drops text on rotated pages (HOM-27: 2/3 tokens on
//   merge_partner_3p.pdf). Before a page is read its in-memory rotation is set to 0, so its text
//   comes out in the page's own (unrotated) reading order and its glyph positions are already in
//   the Pigeon page space (points, origin bottom-left of the unrotated crop box). Callers that need
//   the real rotation read it before (PdfFacts).
// - Pages are read in small windows so a cancel or the character limit stops the work early.
// - PdfBox-Android's own logging is switched off at init: it would log font and file details
//   (rule 30). Nothing here logs.

package com.vecvel.danaview.pdf.text

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxConfig
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import java.io.File
import java.io.IOException
import java.io.StringWriter

object PdfBoxSupport {
    @Volatile private var ready = false

    /** Loads PdfBox-Android's resources (2-4 ms, HOM-27) and silences its logging. Idempotent. */
    fun init(context: Context) {
        if (ready) return
        synchronized(this) {
            if (ready) return
            PDFBoxConfig.setDebugLoggingEnabled(false)
            PDFBoxResourceLoader.init(context.applicationContext)
            ready = true
        }
    }

    /**
     * Opens [file] read-only with [password] (null: the empty password). `passwordRequired` when
     * the file needs another password, `damaged` when PdfBox can't parse it.
     */
    fun load(file: File, password: String?): PDDocument {
        try {
            return PDDocument.load(file, password ?: "")
        } catch (e: InvalidPasswordException) {
            throw PdfFailure(PdfErrorCode.passwordRequired, "password required")
        } catch (e: IOException) {
            if (!file.exists()) throw PdfFailure.notFound("no such file")
            throw PdfFailure.damaged("not a readable PDF")
        } catch (e: RuntimeException) {
            throw PdfFailure.damaged("not a readable PDF")
        } catch (e: StackOverflowError) {
            throw PdfFailure.damaged("not a readable PDF")
        }
    }
}

/** The union of the glyph boxes ([x, y, w, h] per UTF-16 unit, NaN when unset) of `[start, end)`, or null. */
internal fun boxUnion(b: FloatArray, start: Int, end: Int): FloatArray? {
    var x0 = Float.POSITIVE_INFINITY
    var y0 = Float.POSITIVE_INFINITY
    var x1 = Float.NEGATIVE_INFINITY
    var y1 = Float.NEGATIVE_INFINITY
    for (i in start.coerceAtLeast(0) until end.coerceAtMost(b.size / 4)) {
        val x = b[i * 4]
        if (x.isNaN()) continue
        val y = b[i * 4 + 1]
        x0 = minOf(x0, x)
        y0 = minOf(y0, y)
        x1 = maxOf(x1, x + b[i * 4 + 2])
        y1 = maxOf(y1, y + b[i * 4 + 3])
    }
    if (x0 == Float.POSITIVE_INFINITY) return null
    return floatArrayOf(x0, y0, x1 - x0, y1 - y0)
}

/**
 * Reads page text from an open [PDDocument] (not thread-safe: one reader per document at a time,
 * callers serialise). [isCancelled] is checked between windows of [window] pages.
 */
class PdfBoxTextReader(
    private val document: PDDocument,
    private val window: Int = 8,
) : PageTextSource {
    override val pageCount: Int get() = document.numberOfPages

    /**
     * Pages `[first, end)` in order, calling [onPage] for each; [onPage] returns false to stop.
     * With [boxes] each page carries its glyph boxes.
     */
    override fun read(first: Int, end: Int, boxes: Boolean, isCancelled: () -> Boolean, onPage: (PageText) -> Boolean) {
        var start = first.coerceAtLeast(0)
        val stop = end.coerceAtMost(pageCount)
        while (start < stop) {
            if (isCancelled()) throw PdfFailure.cancelled()
            val until = minOf(stop, start + window)
            val pages = readWindow(start, until, boxes)
            for (p in pages) if (!onPage(p)) return
            start = until
        }
    }

    /** One page. */
    override fun page(index: Int, boxes: Boolean): PageText {
        if (index < 0 || index >= pageCount) throw PdfFailure.notFound("no such page")
        return readWindow(index, index + 1, boxes).first()
    }

    private fun readWindow(first: Int, end: Int, boxes: Boolean): List<PageText> {
        val heights = FloatArray(end - first)
        for (i in first until end) {
            val page = document.getPage(i)
            // See the file header: rotated pages are read unrotated (in memory only).
            if (page.rotation != 0) page.rotation = 0
            heights[i - first] = page.cropBox.height
        }
        val stripper = Collector(first, heights, boxes)
        stripper.startPage = first + 1
        stripper.endPage = end
        try {
            stripper.writeText(document, stripper.sink)
        } catch (e: IOException) {
            throw PdfFailure.damaged("page text can't be read")
        } catch (e: RuntimeException) {
            throw PdfFailure.damaged("page text can't be read")
        } catch (e: StackOverflowError) {
            throw PdfFailure.damaged("page text can't be read")
        }
        return (first until end).map { i -> stripper.results[i] ?: PageText(i, "") }
    }

    /** PDFTextStripper that splits its output per page and records glyph boxes per UTF-16 unit. */
    private class Collector(private val first: Int, private val heights: FloatArray, private val boxes: Boolean) : PDFTextStripper() {
        val sink = StringWriter()
        val results = HashMap<Int, PageText>()
        private var pageOffset = 0
        private var pageBoxes = FloatArrayBuilder()

        init {
            lineSeparator = "\n"
            wordSeparator = " "
            setPageStart("")
            setPageEnd("")
            paragraphStart = ""
            paragraphEnd = ""
            articleStart = ""
            articleEnd = ""
            sortByPosition = false
        }

        override fun startPage(page: PDPage?) {
            pageOffset = sink.buffer.length
            pageBoxes = FloatArrayBuilder()
        }

        override fun endPage(page: PDPage?) {
            val index = currentPageNo - 1
            val text = sink.buffer.substring(pageOffset)
            val b = if (boxes) pageBoxes.toArray(text.length) else null
            results[index] = PageText(index, text, b?.let { arr -> { s: Int, e: Int -> boxUnion(arr, s, e) } })
        }

        override fun writeString(text: String, textPositions: MutableList<TextPosition>) {
            if (boxes) {
                val at = sink.buffer.length - pageOffset
                val height = heights.getOrElse(currentPageNo - 1 - first) { 0f }
                record(at, text, textPositions, height)
            }
            super.writeString(text, textPositions)
        }

        /** Boxes for the units of [text] written at page offset [at] from [positions]. */
        private fun record(at: Int, text: String, positions: List<TextPosition>, pageHeight: Float) {
            if (positions.isEmpty() || text.isEmpty()) return
            val units = positions.sumOf { (it.unicode ?: "").length }
            if (units == text.length) {
                var o = at
                for (p in positions) {
                    val n = (p.unicode ?: "").length
                    repeat(n) { pageBoxes.set(o++, p, pageHeight) }
                }
            } else {
                // Normalised words (ligatures, bidi): spread the glyphs over the units.
                for (k in text.indices) {
                    val p = positions[(k.toLong() * positions.size / text.length).toInt().coerceIn(0, positions.size - 1)]
                    pageBoxes.set(at + k, p, pageHeight)
                }
            }
        }
    }

    /** Growable (x, y, w, h) per unit; unset units are NaN. */
    private class FloatArrayBuilder {
        private var data = FloatArray(0)

        fun set(unit: Int, p: TextPosition, pageHeight: Float) {
            ensure(unit + 1)
            val h = p.heightDir.takeIf { it > 0f } ?: p.fontSizeInPt
            // Rotation is 0 here, so DirAdj is page space with a top-left origin.
            data[unit * 4] = p.xDirAdj
            data[unit * 4 + 1] = pageHeight - p.yDirAdj
            data[unit * 4 + 2] = p.widthDirAdj
            data[unit * 4 + 3] = h
        }

        private fun ensure(units: Int) {
            if (data.size >= units * 4) return
            val old = data.size / 4
            val grown = maxOf(units, old * 2, 64)
            val next = FloatArray(grown * 4) { Float.NaN }
            System.arraycopy(data, 0, next, 0, data.size)
            data = next
        }

        fun toArray(units: Int): FloatArray {
            ensure(units)
            return if (data.size == units * 4) data else data.copyOf(units * 4)
        }
    }
}
