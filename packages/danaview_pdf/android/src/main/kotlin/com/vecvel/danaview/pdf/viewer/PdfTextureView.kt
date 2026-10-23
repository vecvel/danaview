// OWNER: HOM-25
//
// One Android PDF texture view (ARCH v1.2 §8 "PDF viewer", D-98g; Pigeon `createTextureView` /
// `setTextureViewport` / `disposeTextureView`). Dart owns scrolling and zoom and sends the
// viewport; this class draws the matching part of the page column (PdfGeometry.kt) into a Flutter
// SurfaceProducer:
//
// - Tiles: visible pages are drawn in 512-pixel tiles at the viewport's render-scale step
//   (Tiles), nearest the centre first, from an LRU cache sized to a few screens. A small preview of
//   each page stands in until its tiles are ready, so scrolling and pinching never show blank pages.
//   After the visible tiles, half a screen above and below is prefetched.
// - Coalescing: viewports arrive faster than pages render; one render pass is queued at a time on
//   the shared render thread and a newer viewport ends the running pass after its current tile.
// - Frames: the whole texture is redrawn per frame (background, white pages, previews, tiles, the
//   search highlight) through `lockHardwareCanvas` (software canvas if a Surface refuses it).
// - Surface lifecycle: `resetInBackground` - Flutter may drop the Surface in the background
//   (onSurfaceCleanup waits for the frame being drawn, then nothing draws) and hands out a new one
//   (onSurfaceAvailable redraws from the caches).
// - Threads: create, setViewport, dispose and the producer callbacks run on the main thread (the
//   thread Flutter's texture registry expects); everything else on the render thread. The view
//   holds a reference to its document until it is disposed.
//
// Selection is not offered on Android (capabilities.selection false): the texture has no text
// layer. Nothing here logs document content (rule 30).

package com.vecvel.danaview.pdf.viewer

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.SystemClock
import android.util.LruCache
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class PdfTextureView(
    val viewId: Long,
    val document: OpenPdf,
    private val producer: TextureRegistry.SurfaceProducer,
    private val render: Handler,
    initial: Viewport,
) : TextureRegistry.SurfaceProducer.Callback {
    /** A search hit to highlight: page and rect in the page's displayed points (origin top-left). */
    data class Highlight(val page: Int, val rect: RectD)

    val layout = TextureLayout(document.pages)

    val textureId: Long get() = producer.id()

    @Volatile var viewport: Viewport = initial
        private set

    @Volatile var highlight: Highlight? = null
        private set

    @Volatile var disposed = false
        private set

    private val surfaceLock = Any()
    private var surface: Surface? = null
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var useHardware = true

    private val scheduled = AtomicBoolean(false)
    private val tiles = object : LruCache<TileKey, Bitmap>(tileBudget(initial)) {
        override fun sizeOf(key: TileKey, value: Bitmap): Int = value.byteCount
    }
    private val previews = object : LruCache<Int, Bitmap>(PREVIEW_BUDGET) {
        override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
    }
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val highlightPaint = Paint().apply { color = HIGHLIGHT }

    // Render thread only: consecutive failed passes.
    private var failures = 0
    private val failureCount = AtomicInteger()

    /** Render passes that failed so far (tests). */
    val renderFailures: Int get() = failureCount.get()

    private val frames = AtomicInteger()
    private val completeFrames = AtomicInteger()

    /** Frames drawn so far (tests). */
    val frameCount: Int get() = frames.get()

    /** Frames drawn with every visible tile in place (tests, timings). */
    val completeFrameCount: Int get() = completeFrames.get()

    /** Called on the render thread after each frame with whether it was complete (tests, timings). */
    @Volatile var onFrame: ((complete: Boolean) -> Unit)? = null

    /** Attaches to the producer and draws the first frame (main thread). */
    fun start() {
        val v = viewport
        producer.setCallback(this)
        producer.setSize(v.widthPx, v.heightPx)
        synchronized(surfaceLock) {
            surface = producer.surface
            surfaceWidth = v.widthPx
            surfaceHeight = v.heightPx
        }
        requestRender()
    }

    /** Moves or resizes the viewport (main thread). */
    fun setViewport(v: Viewport) {
        if (disposed) return
        if (v.widthPx != surfaceWidth || v.heightPx != surfaceHeight) {
            producer.setSize(v.widthPx, v.heightPx)
            val next = producer.surface
            synchronized(surfaceLock) {
                surface = next
                surfaceWidth = v.widthPx
                surfaceHeight = v.heightPx
            }
            render.post { tiles.resize(tileBudget(v)) }
        }
        viewport = v
        requestRender()
    }

    /** Scrolls to the top of [page] (native callers; Dart's texture controller scrolls itself). */
    fun goToPage(page: Int) {
        val v = viewport
        setViewport(clamp(v.copy(offsetY = layout.topOf(page))))
    }

    /** Sets the zoom (clamped to fit … 8 × fit), keeping the centre. */
    fun setScale(scale: Double) {
        val v = viewport
        val s = scale.coerceIn(minScale, maxScale)
        val cy = v.offsetY + v.visibleHeight / 2
        val cx = v.offsetX + v.visibleWidth / 2
        val next = v.copy(scale = s)
        setViewport(clamp(next.copy(offsetX = cx - next.visibleWidth / 2, offsetY = cy - next.visibleHeight / 2)))
    }

    /** Fits the column width. */
    fun zoomToFit() = setScale(minScale)

    val minScale: Double get() = layout.fitScale(viewport.widthPx)
    val maxScale: Double get() = minScale * 8

    /** The page mostly on screen (Dart's rule: the page a third down the viewport). */
    val pageIndex: Int get() = viewport.let { layout.pageAt(it.offsetY + it.visibleHeight / 3) }

    private fun clamp(v: Viewport): Viewport {
        val maxY = max(0.0, layout.height - v.visibleHeight)
        val maxX = max(0.0, layout.width - v.visibleWidth)
        return v.copy(offsetX = v.offsetX.coerceIn(0.0, maxX), offsetY = v.offsetY.coerceIn(0.0, maxY))
    }

    /** Highlights [rect] (page space, Pigeon convention) on [page]; null clears. */
    fun setHighlight(page: Int, x: Double, y: Double, w: Double, h: Double) {
        if (page < 0 || page >= layout.pageCount) return
        highlight = if (w > 0 && h > 0) Highlight(page, layout.pages[page].toDisplay(x, y, w, h)) else null
        requestRender()
    }

    fun clearHighlight() {
        highlight = null
        requestRender()
    }

    /** Releases the texture and this view's reference to the document (main thread). */
    fun dispose() {
        if (disposed) return
        disposed = true
        synchronized(surfaceLock) { surface = null }
        producer.setCallback(null)
        producer.release()
        render.post {
            tiles.evictAll()
            previews.evictAll()
            document.release()
        }
    }

    // ---- SurfaceProducer.Callback (main thread) ----

    override fun onSurfaceAvailable() {
        if (disposed) return
        val next = producer.surface
        synchronized(surfaceLock) { surface = next }
        requestRender()
    }

    override fun onSurfaceCleanup() {
        // Waits for a frame being drawn, then nothing draws until onSurfaceAvailable.
        synchronized(surfaceLock) { surface = null }
    }

    // ---- Render thread ----

    fun requestRender() {
        if (disposed) return
        if (scheduled.compareAndSet(false, true)) render.post(::renderPass)
    }

    private fun renderPass() {
        scheduled.set(false)
        if (disposed) return
        val platform = document.platform ?: return
        val v = viewport
        if (!v.isValid) return
        try {
            renderPass(platform, v)
            failures = 0
        } catch (e: Exception) {
            retryAfterFailure()
        } catch (e: OutOfMemoryError) {
            tiles.evictAll()
            previews.evictAll()
            retryAfterFailure()
        }
    }

    /** A failed pass (a page the platform can't draw, memory) is retried a few times, then waits for the next viewport. */
    private fun retryAfterFailure() {
        failureCount.incrementAndGet()
        if (++failures <= MAX_RETRIES && !disposed) {
            render.postDelayed({ requestRender() }, RETRY_MS * failures)
        }
    }

    private fun renderPass(platform: PlatformPdf, v: Viewport) {
        val step = Tiles.stepFor(v.scale)
        val area = v.rect
        val visible = Tiles.plan(layout, area, step)
        for (page in layout.pagesIn(area.top, area.bottom)) {
            if (previews.get(page) == null) renderPreview(platform, page)
        }
        var missing = visible.count { tiles.get(it) == null }
        drawFrame(v, visible, missing == 0)
        if (missing == 0) {
            prefetch(platform, v, step)
            return
        }
        var last = SystemClock.uptimeMillis()
        for (key in visible) {
            if (disposed) return
            if (tiles.get(key) != null) continue
            if (scheduled.get()) {
                // A newer viewport is queued and will draw; show what is ready now.
                drawFrame(v, visible, false)
                return
            }
            renderTile(platform, key)
            missing--
            val now = SystemClock.uptimeMillis()
            if (missing > 0 && now - last >= PROGRESS_FRAME_MS) {
                drawFrame(v, visible, false)
                last = now
            }
        }
        drawFrame(v, visible, true)
        prefetch(platform, v, step)
    }

    private fun prefetch(platform: PlatformPdf, v: Viewport, step: Int) {
        val area = v.rect
        val margin = area.height / 2
        val around = Tiles.plan(layout, RectD(area.left, area.top - margin, area.right, area.bottom + margin), step)
        val tileBytes = Tiles.SIZE * Tiles.SIZE * 4
        for (key in around) {
            if (disposed || scheduled.get()) return
            if (tiles.get(key) != null) continue
            if (tiles.size() + tileBytes > tiles.maxSize() * 3 / 4) return
            renderTile(platform, key)
        }
    }

    private fun renderTile(platform: PlatformPdf, key: TileKey) {
        val page = layout.pages[key.page]
        val bitmap = Bitmap.createBitmap(Tiles.SIZE, Tiles.SIZE, Bitmap.Config.ARGB_8888)
        val rs = Tiles.scaleOf(key.step)
        PdfPageRenderer.draw(platform, key.page, page, rs, key.col * Tiles.SIZE.toDouble(), key.row * Tiles.SIZE.toDouble(), bitmap)
        tiles.put(key, bitmap)
    }

    private fun renderPreview(platform: PlatformPdf, index: Int) {
        val page = layout.pages[index]
        if (page.displayWidth <= 0 || page.displayHeight <= 0) return
        val s = min(PREVIEW_PX / page.displayWidth, PREVIEW_PX / page.displayHeight)
        val w = max(1, (page.displayWidth * s).roundToInt())
        val h = max(1, (page.displayHeight * s).roundToInt())
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        PdfPageRenderer.draw(platform, index, page, s, 0.0, 0.0, bitmap)
        previews.put(index, bitmap)
    }

    private fun drawFrame(v: Viewport, visible: List<TileKey>, complete: Boolean) {
        synchronized(surfaceLock) {
            val s = surface ?: return
            if (!s.isValid) return
            val canvas = lockCanvas(s) ?: return
            try {
                draw(canvas, v, visible)
            } finally {
                try {
                    s.unlockCanvasAndPost(canvas)
                } catch (e: IllegalStateException) {
                    return
                } catch (e: IllegalArgumentException) {
                    return
                }
            }
        }
        frames.incrementAndGet()
        if (complete) completeFrames.incrementAndGet()
        onFrame?.invoke(complete)
    }

    private fun lockCanvas(s: Surface): Canvas? {
        if (useHardware) {
            try {
                return s.lockHardwareCanvas()
            } catch (e: Exception) {
                useHardware = false
            }
        }
        return try {
            s.lockCanvas(null)
        } catch (e: Exception) {
            null
        }
    }

    private fun draw(canvas: Canvas, v: Viewport, visible: List<TileKey>) {
        canvas.drawColor(BACKGROUND)
        val area = v.rect
        val step = visible.firstOrNull()?.step ?: Tiles.stepFor(v.scale)
        val rs = Tiles.scaleOf(step)
        val h = highlight
        for (page in layout.pagesIn(area.top, area.bottom)) {
            val pr = layout.pageRect(page)
            val sr = v.toScreen(pr).toRectF()
            canvas.save()
            canvas.clipRect(sr)
            canvas.drawColor(Color.WHITE)
            previews.get(page)?.let { canvas.drawBitmap(it, null, sr, paint) }
            for (key in visible) {
                if (key.page != page) continue
                val tile = tiles.get(key) ?: continue
                canvas.drawBitmap(tile, null, v.toScreen(Tiles.tileRect(pr, rs, key.col, key.row)).toRectF(), paint)
            }
            if (h != null && h.page == page) {
                canvas.drawRect(v.toScreen(h.rect.offset(pr.left, pr.top)).toRectF(), highlightPaint)
            }
            canvas.restore()
        }
    }

    private fun RectD.toRectF() = RectF(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())

    companion object {
        /** The column's background between and beside pages. */
        const val BACKGROUND = 0xFFE3E3E6.toInt()

        /** The search highlight (translucent yellow). */
        const val HIGHLIGHT = 0x66FFC800

        /** Long edge of a page preview in pixels. */
        const val PREVIEW_PX = 384.0

        /** Bytes of page previews kept per view. */
        const val PREVIEW_BUDGET = 16 * 1024 * 1024

        /** Retries of a failed render pass, and the delay unit between them. */
        const val MAX_RETRIES = 3
        const val RETRY_MS = 200L

        /** A frame with partial tiles is shown at most this often while tiles render. */
        const val PROGRESS_FRAME_MS = 48L

        /** Tile cache bytes for [v]: three screens of tiles, at least 24 MB, at most a quarter of the heap... */
        fun tileBudget(v: Viewport): Int {
            val perScreen = (ceil(v.widthPx / Tiles.SIZE.toDouble()) + 1) * (ceil(v.heightPx / Tiles.SIZE.toDouble()) + 1)
            val want = (perScreen * 3 * Tiles.SIZE * Tiles.SIZE * 4).toLong()
            val heap = Runtime.getRuntime().maxMemory() / 4
            // ...but never less than one screen of tiles, or a frame could never complete.
            val floor = (perScreen * Tiles.SIZE * Tiles.SIZE * 4).toLong()
            return max(floor, min(max(want, 24L * 1024 * 1024), heap)).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }
    }
}
