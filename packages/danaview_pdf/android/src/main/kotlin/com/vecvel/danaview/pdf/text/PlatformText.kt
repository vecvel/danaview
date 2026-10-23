// OWNER: HOM-25
//
// The platform text layer (API 35+, PageTextSource.kt): `PdfRenderer.Page.getTextContents()` per
// page, line ends normalised from CR LF to LF (as PdfBox and Apple's `PDFPage.string` give them),
// and hit bounds from `selectContent` over the matching platform character range, converted from
// displayed points to the Pigeon page space. A page the platform fails on is read with the PdfBox
// [fallback] when there is one, else it is empty. The renderer is shared with the texture views:
// every call takes its lock for one page only, so tiles keep rendering between pages.

package com.vecvel.danaview.pdf.text

import android.os.Build
import androidx.annotation.RequiresApi
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.viewer.PageGeometry
import com.vecvel.danaview.pdf.viewer.PlatformPdf
import com.vecvel.danaview.pdf.viewer.RectD

@RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
class PlatformTextSource(
    private val platform: PlatformPdf,
    private val pages: List<PageGeometry>,
    private val fallback: PageTextSource?,
) : PageTextSource {
    override val pageCount: Int get() = platform.pageCount

    override fun read(first: Int, end: Int, boxes: Boolean, isCancelled: () -> Boolean, onPage: (PageText) -> Boolean) {
        for (i in first.coerceAtLeast(0) until end.coerceAtMost(pageCount)) {
            if (isCancelled()) throw PdfFailure.cancelled()
            if (!onPage(page(i, boxes))) return
        }
    }

    override fun page(index: Int, boxes: Boolean): PageText {
        if (index < 0 || index >= pageCount) throw PdfFailure.notFound("no such page")
        val raw = platform.pageText(index) ?: return fallback?.page(index, boxes) ?: PageText(index, "")
        val normalised = LineEnds.normalise(raw)
        if (!boxes) return PageText(index, normalised.text)
        return PageText(index, normalised.text) { s, e -> bounds(index, normalised.rawIndex(s), normalised.rawIndex(e)) }
    }

    private fun bounds(index: Int, rawStart: Int, rawEnd: Int): FloatArray? {
        val rects = platform.textBounds(index, rawStart, rawEnd)
        if (rects.isEmpty()) return null
        val geometry = pages.getOrNull(index) ?: return null
        val (pw, ph) = platform.pageSize(index)
        val fx = if (pw > 0) geometry.displayWidth / pw else 1.0
        val fy = if (ph > 0) geometry.displayHeight / ph else 1.0
        val union = RectD(
            rects.minOf { it.left } * fx,
            rects.minOf { it.top } * fy,
            rects.maxOf { it.right } * fx,
            rects.maxOf { it.bottom } * fy,
        )
        val p = geometry.fromDisplay(union)
        return floatArrayOf(p[0].toFloat(), p[1].toFloat(), p[2].toFloat(), p[3].toFloat())
    }
}

/** Text with CR LF / lone CR line ends turned into LF, and the way back to raw offsets. */
class LineEnds private constructor(val text: String, private val raw: IntArray, private val rawLength: Int) {
    /** The raw offset of normalised offset [i] (a range `[s, e)` maps to `[rawIndex(s), rawIndex(e))`). */
    fun rawIndex(i: Int): Int = if (i >= raw.size) rawLength else raw[i.coerceAtLeast(0)]

    companion object {
        fun normalise(s: String): LineEnds {
            if (s.indexOf('\r') < 0) return LineEnds(s, IntArray(s.length) { it }, s.length)
            val out = StringBuilder(s.length)
            val map = IntArray(s.length)
            var n = 0
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '\r') {
                    out.append('\n')
                    map[n++] = i
                    i += if (i + 1 < s.length && s[i + 1] == '\n') 2 else 1
                } else {
                    out.append(c)
                    map[n++] = i
                    i++
                }
            }
            return LineEnds(out.toString(), map.copyOf(n), s.length)
        }
    }
}
