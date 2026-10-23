// OWNER: HOM-25
//
// Pure geometry of the Android texture viewer (no Android classes, JVM-tested):
//
// - [PageGeometry]: a page's crop box in points, unrotated, and its clockwise rotation; the
//   Pigeon surface's page space (origin bottom-left of the unrotated crop box) and the displayed
//   space the renderer and the layout use (rotation applied, origin top-left).
// - [TextureLayout]: the column the Dart side lays out (lib/src/pdf_view.dart `PdfTextureLayout`):
//   pages one under the other with [TextureLayout.GAP] points between them, the column as wide as
//   the widest displayed page; narrower pages are centred in it.
// - [Viewport]: what `setTextureViewport` sends: texture size in pixels, the top-left corner in
//   column points at scale 1 and physical pixels per point.
// - [Tiles]: the tile plan. Pages are rendered in [Tiles.SIZE]-pixel square tiles at a render
//   scale rounded UP to steps of 2^(1/8), so nearby zoom levels share tiles and a tile is only ever
//   drawn downscaled (by at most 9 %), never blurred up.

package com.vecvel.danaview.pdf.viewer

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** A rectangle by its edges (any unit; top < bottom). */
data class RectD(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    val width: Double get() = right - left
    val height: Double get() = bottom - top
    val isEmpty: Boolean get() = !(right > left && bottom > top)

    fun intersect(o: RectD): RectD = RectD(max(left, o.left), max(top, o.top), min(right, o.right), min(bottom, o.bottom))

    fun offset(dx: Double, dy: Double): RectD = RectD(left + dx, top + dy, right + dx, bottom + dy)

    fun scale(s: Double): RectD = RectD(left * s, top * s, right * s, bottom * s)
}

/** The crop box of a page in points (unrotated) and its rotation in degrees clockwise. */
data class PageGeometry(val width: Double, val height: Double, val rotation: Int) {
    val quarterTurned: Boolean get() = rotation == 90 || rotation == 270

    /** Width as displayed (rotation applied). */
    val displayWidth: Double get() = if (quarterTurned) height else width

    /** Height as displayed (rotation applied). */
    val displayHeight: Double get() = if (quarterTurned) width else height

    /**
     * A page-space rect (points, origin bottom-left of the unrotated crop box: the Pigeon
     * convention for search bounds) as a displayed rect (origin top-left, rotation applied).
     */
    fun toDisplay(x: Double, y: Double, w: Double, h: Double): RectD {
        // Unrotated, top-left origin.
        val u0 = x
        val u1 = x + w
        val v0 = height - (y + h)
        val v1 = height - y
        return when (rotation) {
            90 -> RectD(height - v1, u0, height - v0, u1)
            180 -> RectD(width - u1, height - v1, width - u0, height - v0)
            270 -> RectD(v0, width - u1, v1, width - u0)
            else -> RectD(u0, v0, u1, v1)
        }
    }

    /**
     * A displayed rect (origin top-left, rotation applied) as a page-space rect (x, y, width,
     * height; origin bottom-left of the unrotated crop box): the inverse of [toDisplay].
     */
    fun fromDisplay(r: RectD): DoubleArray {
        val u0: Double
        val u1: Double
        val v0: Double
        val v1: Double
        when (rotation) {
            90 -> {
                u0 = r.top; u1 = r.bottom; v0 = height - r.right; v1 = height - r.left
            }
            180 -> {
                u0 = width - r.right; u1 = width - r.left; v0 = height - r.bottom; v1 = height - r.top
            }
            270 -> {
                u0 = width - r.bottom; u1 = width - r.top; v0 = r.left; v1 = r.right
            }
            else -> {
                u0 = r.left; u1 = r.right; v0 = r.top; v1 = r.bottom
            }
        }
        return doubleArrayOf(u0, height - v1, u1 - u0, v1 - v0)
    }

    companion object {
        /** US Letter, for a page whose box can't be read. */
        val LETTER = PageGeometry(612.0, 792.0, 0)

        /** [degrees] as 0, 90, 180 or 270. */
        fun normalizeRotation(degrees: Int): Int {
            val r = ((degrees % 360) + 360) % 360
            return (r / 90) * 90
        }

        /**
         * The geometry of a page the platform renderer reports as [displayW] × [displayH] (integer
         * points, rotation applied) when the PDF parser read [parsed] for it: the parsed geometry
         * when it agrees within [tolerance] points, else the renderer's size unrotated.
         */
        fun reconcile(parsed: PageGeometry?, displayW: Int, displayH: Int, tolerance: Double = 1.5): PageGeometry {
            if (parsed != null && abs(parsed.displayWidth - displayW) <= tolerance && abs(parsed.displayHeight - displayH) <= tolerance) {
                return parsed
            }
            if (displayW <= 0 || displayH <= 0) return parsed ?: LETTER
            return PageGeometry(displayW.toDouble(), displayH.toDouble(), 0)
        }
    }
}

/** The texture view's page column (mirrors Dart's `PdfTextureLayout`). */
class TextureLayout(val pages: List<PageGeometry>) {
    private val tops = DoubleArray(pages.size + 1)

    /** Width of the column in points. */
    val width: Double

    init {
        var y = 0.0
        var w = 0.0
        for (i in pages.indices) {
            tops[i] = y
            y += pages[i].displayHeight + GAP
            w = max(w, pages[i].displayWidth)
        }
        tops[pages.size] = max(0.0, y - GAP)
        width = w
    }

    val pageCount: Int get() = pages.size

    /** Height of the column in points. */
    val height: Double get() = tops[pages.size]

    /** Top of page [index] in points (clamped like Dart's `topOf`). */
    fun topOf(index: Int): Double = if (pages.isEmpty()) 0.0 else tops[index.coerceIn(0, pages.size - 1)]

    /** Page [index]'s displayed rect in column points. */
    fun pageRect(index: Int): RectD {
        val p = pages[index]
        val left = (width - p.displayWidth) / 2
        return RectD(left, tops[index], left + p.displayWidth, tops[index] + p.displayHeight)
    }

    /** The page at column height [y] (Dart's `pageAt`). */
    fun pageAt(y: Double): Int {
        var lo = 0
        var hi = pages.size - 1
        if (hi < 0) return 0
        while (lo < hi) {
            val mid = (lo + hi + 1) ushr 1
            if (tops[mid] <= y) lo = mid else hi = mid - 1
        }
        return lo
    }

    /** Pages whose rects meet the band [top, bottom) (column points), in order. */
    fun pagesIn(top: Double, bottom: Double): IntRange {
        if (pages.isEmpty() || bottom <= top) return IntRange.EMPTY
        val first = pageAt(top)
        var last = pageAt(bottom)
        if (last > first && tops[last] >= bottom) last--
        return first..last
    }

    /** The zoom that fits the column width into [widthPx] pixels. */
    fun fitScale(widthPx: Int): Double = if (width <= 0) 1.0 else widthPx / width

    companion object {
        /** Points between pages (Dart's `PdfTextureLayout.gap`). */
        const val GAP = 8.0
    }
}

/** A texture view's viewport (Pigeon `PdfViewportMsg`). */
data class Viewport(val widthPx: Int, val heightPx: Int, val offsetX: Double, val offsetY: Double, val scale: Double) {
    /** Visible width in column points. */
    val visibleWidth: Double get() = widthPx / scale

    /** Visible height in column points. */
    val visibleHeight: Double get() = heightPx / scale

    /** The visible part of the column in points. */
    val rect: RectD get() = RectD(offsetX, offsetY, offsetX + visibleWidth, offsetY + visibleHeight)

    /** A column-point rect in texture pixels. */
    fun toScreen(r: RectD): RectD = r.offset(-offsetX, -offsetY).scale(scale)

    /** Whether the viewport is drawable. */
    val isValid: Boolean get() = widthPx > 0 && heightPx > 0 && scale.isFinite() && scale > 0 && offsetX.isFinite() && offsetY.isFinite()
}

/** One tile: page, render-scale step and column / row in tile units. */
data class TileKey(val page: Int, val step: Int, val col: Int, val row: Int)

object Tiles {
    /** Tile edge in pixels. */
    const val SIZE = 512

    /** Steps per doubling of the render scale. */
    const val STEPS_PER_OCTAVE = 8

    /** Smallest and largest render scale (pixels per point). */
    const val MIN_SCALE = 1.0 / 64
    const val MAX_SCALE = 64.0

    /** The step of the smallest render scale >= [scale]. */
    fun stepFor(scale: Double): Int {
        val s = scale.coerceIn(MIN_SCALE, MAX_SCALE)
        return ceil(ln(s) / ln(2.0) * STEPS_PER_OCTAVE - 1e-9).toInt()
    }

    /** The render scale of [step]. */
    fun scaleOf(step: Int): Double = 2.0.pow(step.toDouble() / STEPS_PER_OCTAVE)

    /** Page [pageRect] (displayed, column points) tile [col], [row] at render scale [renderScale], in column points. */
    fun tileRect(pageRect: RectD, renderScale: Double, col: Int, row: Int): RectD {
        val unit = SIZE / renderScale
        val r = RectD(pageRect.left + col * unit, pageRect.top + row * unit, pageRect.left + (col + 1) * unit, pageRect.top + (row + 1) * unit)
        return r
    }

    /**
     * The tiles of [layout] that meet [area] (column points) at [step], nearest to the area's
     * centre first.
     */
    fun plan(layout: TextureLayout, area: RectD, step: Int): List<TileKey> {
        if (area.isEmpty) return emptyList()
        val rs = scaleOf(step)
        val unit = SIZE / rs
        val cx = (area.left + area.right) / 2
        val cy = (area.top + area.bottom) / 2
        val out = ArrayList<Pair<TileKey, Double>>()
        for (page in layout.pagesIn(area.top, area.bottom)) {
            val pr = layout.pageRect(page)
            val vis = pr.intersect(area)
            if (vis.isEmpty) continue
            val cols = max(1, ceil(pr.width / unit - 1e-9).toInt())
            val rows = max(1, ceil(pr.height / unit - 1e-9).toInt())
            val c0 = floor((vis.left - pr.left) / unit).toInt().coerceIn(0, cols - 1)
            val c1 = (ceil((vis.right - pr.left) / unit).toInt() - 1).coerceIn(c0, cols - 1)
            val r0 = floor((vis.top - pr.top) / unit).toInt().coerceIn(0, rows - 1)
            val r1 = (ceil((vis.bottom - pr.top) / unit).toInt() - 1).coerceIn(r0, rows - 1)
            for (r in r0..r1) for (c in c0..c1) {
                val tx = pr.left + (c + 0.5) * unit
                val ty = pr.top + (r + 0.5) * unit
                val d = (tx - cx) * (tx - cx) + (ty - cy) * (ty - cy)
                out += TileKey(page, step, c, r) to d
            }
        }
        out.sortBy { it.second }
        return out.map { it.first }
    }
}
