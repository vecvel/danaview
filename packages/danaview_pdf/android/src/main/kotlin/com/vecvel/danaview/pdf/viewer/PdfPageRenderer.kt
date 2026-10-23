// OWNER: HOM-25
//
// Page drawing on top of [PlatformPdf]: thumbnails (a page fitted into a box on white paper, PNG)
// and viewer tiles. Every page is drawn into the displayed size the layout gave it
// ([PageGeometry.displayWidth] × [PageGeometry.displayHeight]); when the platform's own size of the
// page differs (PdfRenderer reports integer points), the content is scaled to fill it, so pages,
// tiles and search highlights line up exactly.

package com.vecvel.danaview.pdf.viewer

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import com.vecvel.danaview.pdf.glue.PdfFailure
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** An encoded page image. */
class RenderedImage(val png: ByteArray, val width: Int, val height: Int)

object PdfPageRenderer {
    /** Largest thumbnail edge (Apple: 8192). */
    const val MAX_THUMBNAIL_PX = 8192

    /**
     * The transform of page [index] at [scale] pixels per point, shifted by (-[dx], -[dy]) pixels;
     * call under the renderer's lock.
     */
    private fun transform(platform: PlatformPdf, index: Int, page: PageGeometry, scale: Double, dx: Double, dy: Double): Matrix {
        val (pw, ph) = platform.pageSize(index)
        val fx = if (pw > 0) page.displayWidth / pw else 1.0
        val fy = if (ph > 0) page.displayHeight / ph else 1.0
        return Matrix().apply {
            setScale((scale * fx).toFloat(), (scale * fy).toFloat())
            postTranslate((-dx).toFloat(), (-dy).toFloat())
        }
    }

    /** Page [index] fitted into [maxWidth] × [maxHeight] pixels on white, as PNG. */
    fun thumbnail(platform: PlatformPdf, index: Int, page: PageGeometry, maxWidth: Int, maxHeight: Int): RenderedImage {
        if (maxWidth <= 0 || maxHeight <= 0 || maxWidth > MAX_THUMBNAIL_PX || maxHeight > MAX_THUMBNAIL_PX) {
            throw PdfFailure.invalid("thumbnail size out of range")
        }
        if (index < 0 || index >= platform.pageCount) throw PdfFailure.notFound("no such page")
        val pw = page.displayWidth
        val ph = page.displayHeight
        if (pw <= 0 || ph <= 0) throw PdfFailure.damaged("empty page box")
        val scale = min(maxWidth / pw, maxHeight / ph)
        val width = max(1, (pw * scale).roundToInt())
        val height = max(1, (ph * scale).roundToInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.WHITE)
            platform.lock.lock()
            try {
                platform.render(index, bitmap, transform(platform, index, page, scale, 0.0, 0.0))
            } finally {
                platform.lock.unlock()
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            return RenderedImage(out.toByteArray(), width, height)
        } finally {
            bitmap.recycle()
        }
    }

    /** Draws [page] at [scale] into [bitmap] (filled white first) with its top-left at pixel (-[dx], -[dy]). */
    fun draw(platform: PlatformPdf, index: Int, page: PageGeometry, scale: Double, dx: Double, dy: Double, bitmap: Bitmap) {
        bitmap.eraseColor(Color.WHITE)
        platform.lock.lock()
        try {
            platform.render(index, bitmap, transform(platform, index, page, scale, dx, dy))
        } finally {
            platform.lock.unlock()
        }
    }
}
