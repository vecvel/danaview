// OWNER: HOM-29A
//
// The file's own annotation appearances that PdfRenderer does not draw (Mac 9d15fe3e item 2):
// PdfRenderer draws no annotations before API 35 and only text notes and highlights from 35
// (RenderParams flags, viewer/PlatformPdf.kt), so Ink, FreeText, Stamp (and the other markup
// kinds; before 35 also Highlight and Text) would be missing from the tiles. This layer draws their
// appearance streams (/AP) with PdfBox-Android's renderer over each tile and page preview, after
// the platform has drawn the page.
//
// - Which pages: PdfFacts lists the pages with such annotations at open (subtypes only), so files
//   without them never pay for this layer.
// - How: on first use the render thread opens its own read-only PdfBox document of the file (the
//   viewer's PdfBox document belongs to the text thread and has its rotations zeroed). For each
//   listed page a page of an in-memory overlay document gets the page's boxes and /Rotate, empty
//   content and only the annotations to draw; PDFRenderer.renderPageToGraphics draws that page onto
//   the tile's canvas at the tile's scale (a transparent background paint, so only the appearances
//   land on the tile). Hidden and no-view annotations are skipped by PdfBox.
// - Failures (a file PdfBox can't read, a broken appearance) leave the tile as the platform drew
//   it. Render thread only; closed with the document. Nothing here logs.

package com.vecvel.danaview.pdf.viewer

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.rendering.PDFRenderer
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import java.io.File

class PdfAppearanceLayer(
    private val file: File,
    private val password: String?,
    /** Page index → the subtypes of its annotations this layer may draw (from [PdfFacts]). */
    private val pages: Map<Int, Set<String>>,
) {
    private var source: PDDocument? = null
    private var overlay: PDDocument? = null
    private var renderer: PDFRenderer? = null
    private var failed = false
    private val overlayIndex = HashMap<String, Int>()
    private val transparent = Paint().apply { color = Color.TRANSPARENT }

    /** True when page [index] may have something to draw. */
    fun covers(index: Int): Boolean = !failed && pages.containsKey(index)

    /**
     * Draws page [index]'s appearances onto [canvas] at [scale] pixels per point with the page's
     * displayed top-left at pixel (-[dx], -[dy]); [platformDraws] are the subtypes the platform
     * renderer already drew.
     */
    fun draw(index: Int, canvas: Canvas, scale: Double, dx: Double, dy: Double, platformDraws: Set<String>) {
        val subtypes = pages[index] ?: return
        if (failed || subtypes.all { it in platformDraws }) return
        try {
            val r = renderer ?: open() ?: return
            val key = "$index:${platformDraws.sorted().joinToString(",")}"
            val target = overlayIndex[key] ?: addPage(index, platformDraws).also { overlayIndex[key] = it }
            if (target < 0) return
            canvas.save()
            canvas.translate((-dx).toFloat(), (-dy).toFloat())
            r.renderPageToGraphics(target, transparent, canvas, scale.toFloat(), scale.toFloat())
            canvas.restore()
        } catch (e: Exception) {
            // A broken appearance: the platform's drawing stays.
        } catch (e: OutOfMemoryError) {
            failed = true
        }
    }

    /** Closes the documents (render thread). */
    fun close() {
        try {
            overlay?.close()
        } catch (_: Exception) {
        }
        try {
            source?.close()
        } catch (_: Exception) {
        }
        overlay = null
        source = null
        renderer = null
        overlayIndex.clear()
    }

    private fun open(): PDFRenderer? {
        if (failed) return null
        return try {
            val s = PdfBoxSupport.load(file, password)
            source = s
            val o = PDDocument()
            overlay = o
            PDFRenderer(o).also { renderer = it }
        } catch (e: Exception) {
            failed = true
            close()
            null
        }
    }

    /** Adds the overlay page of source page [index] without [platformDraws]; -1 when nothing is left. */
    private fun addPage(index: Int, platformDraws: Set<String>): Int {
        val s = source ?: return -1
        val o = overlay ?: return -1
        if (index < 0 || index >= s.numberOfPages) return -1
        val page = s.getPage(index)
        val annots = COSArray()
        for (a in page.annotations) {
            val subtype = a.subtype ?: continue
            if (subtype !in DRAWN || subtype in platformDraws) continue
            if (a.cosObject.getDictionaryObject(COSName.AP) !is COSDictionary) continue
            annots.add(a.cosObject)
        }
        if (annots.size() == 0) return -1
        val copy = PDPage(PDRectangle(page.mediaBox.cosArray)).apply {
            cropBox = page.cropBox
            rotation = page.rotation
        }
        copy.cosObject.setItem(COSName.ANNOTS, annots)
        o.addPage(copy)
        return o.numberOfPages - 1
    }

    companion object {
        /** The subtypes drawn from their appearance streams (form fields and links are not). */
        val DRAWN: Set<String> = setOf(
            "Ink", "FreeText", "Stamp", "Highlight", "Underline", "StrikeOut", "Squiggly",
            "Text", "Square", "Circle", "Line", "Polygon", "PolyLine", "Caret", "FileAttachment",
        )

        /** What PdfRenderer draws itself with the annotation flags (API 35+, viewer/PlatformPdf.kt). */
        val PLATFORM_FLAGGED: Set<String> = setOf("Highlight", "Text")
    }
}
