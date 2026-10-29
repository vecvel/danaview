// OWNER: HOM-29A
// EXTENDED: HOM-30A (stamps: the selected one's dashed mark and resize handle for the `place` input).
//
// The annotate-mode preview of a texture view (PdfAnnotateHostApi.showAnnotations, HOM-29 amendment):
// the session's items drawn over the page tiles on every frame, in page space through the page's
// transform (rotation applied), so they move and zoom with the page. Nothing is written to the
// file. As on Apple (darwin/Classes/Annotate/PdfAnnotateView.swift): markup, ink, text boxes
// (fitted like the writer fits them, text turning with the page), note icons, image stamps
// (turned clockwise, quarter turns filling their rect); the selected item gets a dashed neutral
// mark, and in `place` mode a selected stamp also gets the round resize handle (22 dp, light fill,
// grey hairline) at its lower trailing corner on screen.
//
// Touches never reach a texture: on Android the Dart texture view turns gestures into the
// annotate events (lib/src/pdf_texture_annotate.dart) and sends the live drag back as items.
// Stamp images are decoded once per path (at most 1024 px) on the render thread. Nothing here logs.

package com.vecvel.danaview.pdf.viewer

import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.util.LruCache
import com.vecvel.danaview.pdf.annotate.PdfAnnotateCore
import com.vecvel.danaview.pdf.annotate.PdfAnnotationKind
import com.vecvel.danaview.pdf.annotate.PdfAnnotationSpec
import com.vecvel.danaview.pdf.annotate.PdfBox
import com.vecvel.danaview.pdf.annotate.PdfStampSpec
import kotlin.math.max
import kotlin.math.min

/** One item of an annotate session: exactly one of [annotation] and [stamp]. */
data class PreviewItem(val id: String, val annotation: PdfAnnotationSpec?, val stamp: PdfStampSpec?) {
    val pageIndex: Int get() = annotation?.pageIndex ?: stamp?.pageIndex ?: -1
}

/** What a texture view shows of an annotate session. */
data class PreviewState(val placeMode: Boolean, val items: List<PreviewItem>, val selectedId: String?) {
    companion object {
        val NONE = PreviewState(false, emptyList(), null)
    }
}

/** Draws [PreviewState]s (render thread only). */
class PdfAnnotatePreview {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val multiply = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        xfermode = PorterDuffXfermode(PorterDuff.Mode.MULTIPLY)
    }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = PdfAnnotateCore.FREE_TEXT_FONT_SIZE.toFloat() }
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val density = Resources.getSystem().displayMetrics.density
    private val mark = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = MARK_COLOR
        strokeWidth = max(1f, density)
        pathEffect = DashPathEffect(floatArrayOf(4 * density, 3 * density), 0f)
    }
    private val handleFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = HANDLE_FILL }
    private val handleLine = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = MARK_COLOR; strokeWidth = max(1f, density) }
    private val images = object : LruCache<String, Bitmap>(IMAGE_BUDGET) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }
    private val missing = HashSet<String>()

    /**
     * Draws the items of [state] on page [index] ([page]); [toScreen] maps page space (Pigeon,
     * y up) to the texture's pixels.
     */
    fun draw(canvas: Canvas, state: PreviewState, index: Int, page: PageGeometry, toScreen: Matrix) {
        var selected: PreviewItem? = null
        for (item in state.items) {
            if (item.pageIndex != index) continue
            canvas.save()
            canvas.concat(toScreen)
            item.annotation?.let { drawAnnotation(canvas, it, page) }
            item.stamp?.let { drawStamp(canvas, it) }
            canvas.restore()
            if (item.id == state.selectedId) selected = item
        }
        val s = selected ?: return
        val bounds = boundsOf(s, page) ?: return
        val r = RectF(bounds.x.toFloat(), bounds.y.toFloat(), bounds.right.toFloat(), bounds.top.toFloat())
        toScreen.mapRect(r)
        val pad = 3 * density
        canvas.drawRect(r.left - pad, r.top - pad, r.right + pad, r.bottom + pad, mark)
        if (state.placeMode && s.stamp != null) {
            val radius = HANDLE_DP / 2 * density
            canvas.drawCircle(r.right, r.bottom, radius, handleFill)
            canvas.drawCircle(r.right, r.bottom, radius, handleLine)
        }
    }

    /** Drops cached images (the view goes). */
    fun clear() {
        images.evictAll()
        missing.clear()
    }

    private fun drawAnnotation(canvas: Canvas, a: PdfAnnotationSpec, page: PageGeometry) {
        val color = a.colorArgb.toInt()
        when (a.kind) {
            PdfAnnotationKind.HIGHLIGHT -> {
                multiply.color = color
                for (r in a.rects) canvas.drawRect(r.x.toFloat(), r.y.toFloat(), r.right.toFloat(), r.top.toFloat(), multiply)
            }
            PdfAnnotationKind.UNDERLINE, PdfAnnotationKind.STRIKE_OUT -> {
                stroke.color = color
                stroke.strokeCap = Paint.Cap.BUTT
                for (r in a.rects) {
                    stroke.strokeWidth = max(0.5, r.height / 14).toFloat()
                    val y = if (a.kind == PdfAnnotationKind.UNDERLINE) r.y + r.height / 7 else r.y + r.height * 0.4
                    canvas.drawLine(r.x.toFloat(), y.toFloat(), r.right.toFloat(), y.toFloat(), stroke)
                }
                stroke.strokeCap = Paint.Cap.ROUND
            }
            PdfAnnotationKind.INK -> {
                stroke.color = color
                stroke.strokeWidth = max(a.lineWidth, 0.5).toFloat()
                for (s in a.strokes) {
                    if (s.size < 2) continue
                    val path = Path().apply {
                        moveTo(s[0].toFloat(), s[1].toFloat())
                        if (s.size == 2) lineTo(s[0].toFloat() + 0.01f, s[1].toFloat())
                        for (i in 2 until s.size step 2) lineTo(s[i].toFloat(), s[i + 1].toFloat())
                    }
                    canvas.drawPath(path, stroke)
                }
            }
            PdfAnnotationKind.FREE_TEXT -> {
                val box = PdfAnnotateCore.freeTextBounds(a.text.orEmpty(), a.rects.firstOrNull() ?: return, page.width, page.height)
                text.color = color
                canvas.save()
                // Page space is y up: flip around the box's top edge, then lay the lines out downwards.
                canvas.translate((box.x + PdfAnnotateCore.FREE_TEXT_PADDING).toFloat(), (box.top - PdfAnnotateCore.FREE_TEXT_PADDING).toFloat())
                canvas.scale(1f, -1f)
                val lineHeight = (PdfAnnotateCore.FREE_TEXT_FONT_SIZE * 1.15 * 1.25).toFloat()
                var y = -text.ascent()
                for (line in PdfAnnotateCore.wrap(a.text.orEmpty(), max(box.width - 2 * PdfAnnotateCore.FREE_TEXT_PADDING, 1.0))) {
                    canvas.drawText(line, 0f, y, text)
                    y += lineHeight
                }
                canvas.restore()
            }
            PdfAnnotationKind.NOTE -> {
                val r = a.rects.firstOrNull() ?: return
                val n = PdfAnnotateCore.NOTE_SIZE.toFloat()
                val x = r.x.toFloat()
                val y = r.y.toFloat()
                fill.color = color or 0xFF000000.toInt()
                canvas.drawRoundRect(x + 2, y + 2, x + n - 2, y + n - 2, 3f, 3f, fill)
                stroke.color = Color.WHITE
                stroke.strokeWidth = 1.5f
                for (k in 0 until 3) {
                    val ly = y + n - 8 - k * 4
                    canvas.drawLine(x + 7, ly, x + n - 7, ly, stroke)
                }
            }
        }
    }

    private fun drawStamp(canvas: Canvas, s: PdfStampSpec) {
        val image = image(s.imagePath) ?: return
        val r = s.rect
        val swap = PdfAnnotateCore.isQuarterTurn(s.rotationDegrees)
        val w = (if (swap) r.height else r.width).toFloat()
        val h = (if (swap) r.width else r.height).toFloat()
        canvas.save()
        canvas.translate((r.x + r.width / 2).toFloat(), (r.y + r.height / 2).toFloat())
        // y is up here, so a clockwise turn on screen is a negative canvas rotation.
        if (s.rotationDegrees != 0.0) canvas.rotate(-s.rotationDegrees.toFloat())
        canvas.scale(1f, -1f)
        canvas.drawBitmap(image, null, RectF(-w / 2, -h / 2, w / 2, h / 2), bitmapPaint)
        canvas.restore()
    }

    private fun image(path: String): Bitmap? {
        images.get(path)?.let { return it }
        if (path in missing) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= IMAGE_MAX_PX) sample *= 2
        val bitmap = try {
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (e: OutOfMemoryError) {
            null
        }
        if (bitmap == null) {
            missing += path
            return null
        }
        images.put(path, bitmap)
        return bitmap
    }

    companion object {
        /** The neutral grey of the selection mark and the handle's hairline. */
        const val MARK_COLOR = 0xFF8E8E93.toInt()

        /** The handle's light fill. */
        const val HANDLE_FILL = 0xFFF2F2F7.toInt()

        /** Diameter of the resize handle (dp). */
        const val HANDLE_DP = 22f

        /** Stamp images are previewed at most this many pixels on their longer side. */
        const val IMAGE_MAX_PX = 1024

        /** Bytes of decoded stamp images kept per view. */
        const val IMAGE_BUDGET = 16 * 1024 * 1024

        /** The page-space bounds of [item] on [page] (what is drawn and hit-tested). */
        fun boundsOf(item: PreviewItem, page: PageGeometry): PdfBox? {
            item.stamp?.let { return it.rect }
            val a = item.annotation ?: return null
            return when (a.kind) {
                PdfAnnotationKind.INK -> {
                    var l = Double.MAX_VALUE
                    var b = Double.MAX_VALUE
                    var r = -Double.MAX_VALUE
                    var t = -Double.MAX_VALUE
                    for (s in a.strokes) for (i in 0 until s.size - 1 step 2) {
                        l = min(l, s[i]); r = max(r, s[i]); b = min(b, s[i + 1]); t = max(t, s[i + 1])
                    }
                    if (l > r) null else PdfBox(l, b, r - l, t - b).inset(-a.lineWidth / 2)
                }
                PdfAnnotationKind.FREE_TEXT -> a.rects.firstOrNull()?.let { PdfAnnotateCore.freeTextBounds(a.text.orEmpty(), it, page.width, page.height) }
                PdfAnnotationKind.NOTE -> a.rects.firstOrNull()?.let { PdfBox(it.x, it.y, PdfAnnotateCore.NOTE_SIZE, PdfAnnotateCore.NOTE_SIZE) }
                else -> a.rects.reduceOrNull { x, y -> x.union(y) }
            }
        }

        /**
         * The transform from page space (Pigeon: points, origin bottom-left of the unrotated crop
         * box) of [page] to texture pixels, with the page's displayed rect at [pageRect] (column
         * points) in viewport [v].
         */
        fun pageToScreen(page: PageGeometry, pageRect: RectD, v: Viewport): Matrix {
            fun at(x: Double, y: Double): FloatArray {
                val d = page.toDisplay(x, y, 0.0, 0.0)
                val s = v.toScreen(RectD(d.left, d.top, d.left, d.top).offset(pageRect.left, pageRect.top))
                return floatArrayOf(s.left.toFloat(), s.top.toFloat())
            }
            val src = floatArrayOf(0f, 0f, page.width.toFloat(), 0f, 0f, page.height.toFloat())
            val a = at(0.0, 0.0)
            val b = at(page.width, 0.0)
            val c = at(0.0, page.height)
            val dst = floatArrayOf(a[0], a[1], b[0], b[1], c[0], c[1])
            return Matrix().apply { setPolyToPoly(src, 0, dst, 0, 3) }
        }
    }
}
