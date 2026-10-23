// OWNER: HOM-25
//
// Where page text comes from on Android (ARCH v1.2 §8 "PDF text (search)"):
//
// - API 35+: the platform (`PdfRenderer.Page.getTextContents()`, PDFium; ~1 ms a page) with hit
//   bounds from `selectContent` (PlatformText.kt). Rotated pages are read correctly. A page the
//   platform can't read falls back to PdfBox when the document has it.
// - Before API 35, and for files the platform renderer can't open: PdfBox-Android
//   (PdfBoxText.kt; ~20 ms a page in a debuggable build), with /Rotate handled.
//
// Text offsets are UTF-16 units into the page text a source returns; the same source serves
// extraction and search on a device, so search ranges always index the text extractText returns.

package com.vecvel.danaview.pdf.text

/** The text of one page; [bounds] gives a range's box in page space (x, y, w, h) when known. */
class PageText(val pageIndex: Int, val text: String, private val boundsOf: ((Int, Int) -> FloatArray?)? = null) {
    /** The box of `[start, end)` in page space (points, origin bottom-left of the unrotated crop box), or null. */
    fun bounds(start: Int, end: Int): FloatArray? = if (start >= end) null else boundsOf?.invoke(start, end)
}

/** Reads page text; one reader per document at a time (callers serialise). */
interface PageTextSource {
    val pageCount: Int

    /**
     * Pages `[first, end)` in order, calling [onPage] for each until it returns false; with
     * [boxes] the pages can answer [PageText.bounds]. [isCancelled] is checked between pages or
     * page windows (`cancelled`).
     */
    fun read(first: Int, end: Int, boxes: Boolean, isCancelled: () -> Boolean, onPage: (PageText) -> Boolean)

    /** One page. */
    fun page(index: Int, boxes: Boolean): PageText
}
