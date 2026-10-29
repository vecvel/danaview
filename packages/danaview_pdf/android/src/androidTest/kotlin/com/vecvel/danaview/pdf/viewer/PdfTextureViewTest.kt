// OWNER: HOM-25
//
// Instrumented tests of the texture viewer (HOM-25) through PdfViewHostApiImpl over a fake
// SurfaceProducer that reads every frame back: first frame and the 200-page first-page open time
// (limit 500 ms; Apple 37 ms), tiles at zoom against a direct render of the same region, the
// /Rotate 90 page, the annotated page (drawn and read without the platform getPageAnnotations(),
// whose NPE aborts the process on API 36.1+: HOM-27, and on API 37 here; PdfAnnotationsGuardTest
// keeps it out of the code), search highlights, resize, the resetInBackground surface cycle, dispose, thumbnails,
// selection (not offered) and errors.

package com.vecvel.danaview.pdf.viewer

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfDisplayModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfImageMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchHitMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchOptionsMsg
import com.vecvel.danaview.pdf.pigeon.PdfSearchResultMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfThumbnailRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfViewportMsg
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class PdfTextureViewTest {
    private val store = PdfDocumentStore()
    private val threads = PdfThreads()
    private val textures = FakeTextureRegistry()
    private val api = PdfViewHostApiImpl(store, textures, threads)

    private val w = 1080
    private val h = 2340

    @After
    fun tearDown() {
        onMain { api.disposeAll() }
        store.removeAll().forEach { doc -> threads.render.post { doc.release() } }
        threads.render.post { threads.shutdown() }
    }

    private fun open(path: String, password: String? = null): PdfSummary = store.open(path, password)

    private fun create(handle: Long, page: Int = 0, width: Int = w, height: Int = h): PdfTextureViewMsg =
        awaitCall<PdfTextureViewMsg> { api.createTextureView(PdfTextureViewRequestMsg(handle, width.toLong(), height.toLong(), page.toLong(), PdfDisplayModeMsg.CONTINUOUS), it) }.getOrThrow()

    private fun producer(msg: PdfTextureViewMsg): FakeSurfaceProducer = textures.producers.single { it.id() == msg.textureId }

    private fun setViewport(viewId: Long, v: Viewport) = onMain {
        api.setTextureViewport(viewId, PdfViewportMsg(v.widthPx.toLong(), v.heightPx.toLong(), v.offsetX, v.offsetY, v.scale))
    }

    /** Draws [page] region [area] (column points) of [layout] at [scale] directly, as the reference. */
    private fun reference(doc: OpenPdf, layout: TextureLayout, page: Int, v: Viewport): Bitmap {
        val bmp = Bitmap.createBitmap(v.widthPx, v.heightPx, Bitmap.Config.ARGB_8888)
        val pr = layout.pageRect(page)
        val dx = (v.offsetX - pr.left) * v.scale
        val dy = (v.offsetY - pr.top) * v.scale
        PdfPageRenderer.draw(doc.requirePlatform(), page, layout.pages[page], v.scale, dx, dy, bmp)
        return bmp
    }

    /** Mean absolute channel difference and the share of pixels differing by > 64 in any channel. */
    private fun diff(frame: Frame, ref: Bitmap, x0: Int, y0: Int, x1: Int, y1: Int): Pair<Double, Double> {
        var sum = 0L
        var big = 0
        var n = 0
        for (y in y0 until y1 step 2) for (x in x0 until x1 step 2) {
            val a = frame.pixel(x, y)
            val b = ref.getPixel(x, y)
            val d = maxOf(abs(Color.red(a) - Color.red(b)), abs(Color.green(a) - Color.green(b)), abs(Color.blue(a) - Color.blue(b)))
            sum += d
            if (d > 64) big++
            n++
        }
        return sum.toDouble() / n to big.toDouble() / n
    }

    @Test
    fun firstPageOfTheTimingFileOpensUnder500Ms() {
        val path = Fixtures.path(Fixtures.TEXT_200)
        // The plugin warms the PDF code a few seconds after attach (PdfWarmUp); instrumentation
        // argument hom25NoWarmUp=true measures a truly cold first open instead (run this test alone).
        val warm = InstrumentationRegistry.getArguments().getString("hom25NoWarmUp") != "true"
        if (warm) {
            val t = System.nanoTime()
            PdfWarmUp.run(Fixtures.context.cacheDir)
            Log.i(HOM25_TAG, "warm-up (API ${Build.VERSION.SDK_INT}): %.1f ms".format((System.nanoTime() - t) / 1e6))
        }
        val runs = ArrayList<DoubleArray>()
        repeat(5) { run ->
            val t0 = System.nanoTime()
            val s = open(path)
            val tOpen = System.nanoTime()
            val msg = create(s.handle)
            val view = onMain { api.view(msg.viewId) }
            awaitComplete(view, 0)
            val tFrame = System.nanoTime()
            runs += doubleArrayOf((tOpen - t0) / 1e6, (tFrame - t0) / 1e6)
            Log.i(HOM25_TAG, "text_200p run ${run + 1}: open %.1f ms, first complete frame %.1f ms".format((tOpen - t0) / 1e6, (tFrame - t0) / 1e6))
            onMain { api.disposeTextureView(msg.viewId) }
            threads.render.post { store.remove(s.handle)?.release() }
        }
        val firsts = runs.map { it[1] }.sorted()
        Log.i(HOM25_TAG, "text_200p first page (API ${Build.VERSION.SDK_INT}, ${if (warm) "after warm-up" else "NO warm-up"}): first %.1f ms, median %.1f ms, max %.1f ms".format(runs[0][1], firsts[2], firsts.last()))
        // The cold (no warm-up) mode only measures: right after an emulator boot it reads seconds.
        // The 500 ms budget is a device number: it applies with the instrumentation argument
        // DV_PERF_STRICT=1; a loaded emulator gets 4x (the frame itself is checked in both modes).
        if (warm) {
            val strict = InstrumentationRegistry.getArguments().getString("DV_PERF_STRICT") == "1"
            val bound = if (strict) 500.0 else 2_000.0
            assertTrue("first page ${runs[0][1]} ms (bound $bound)", runs[0][1] < bound)
            assertTrue("median first page ${firsts[2]} ms (bound $bound)", firsts[2] < bound)
        }
    }

    @Test
    fun firstFrameShowsPagesOnTheBackground() {
        val s = open(Fixtures.path(Fixtures.MERGE_3))
        val msg = create(s.handle)
        assertEquals(3L, msg.state.pageCount)
        assertEquals(0L, msg.state.pageIndex)
        assertFalse(msg.state.hasSelection)
        val layout = TextureLayout(s.pages)
        assertEquals(layout.fitScale(w), msg.state.scale, 1e-9)
        assertEquals(msg.state.scale, msg.state.minScale, 1e-9)
        assertEquals(msg.state.scale * 8, msg.state.maxScale, 1e-9)
        val view = onMain { api.view(msg.viewId) }
        awaitComplete(view, 0)
        val frame = producer(msg).settledFrame()
        assertEquals(w, frame.width)
        assertEquals(h, frame.height)
        val scale = msg.state.scale
        // Page 1 (portrait, narrower than the landscape pages): background on both sides.
        val p0 = view.viewport.toScreen(layout.pageRect(0))
        assertTrue(isBackground(frame.pixel(2, (p0.top + 50).toInt())))
        assertTrue(isWhite(frame.pixel((p0.left + 10).roundToInt(), (p0.top + 10).roundToInt())))
        // Text is drawn on page 1 (its heading and body).
        assertTrue(frame.count(p0.left.toInt(), p0.top.toInt(), p0.right.toInt(), p0.bottom.toInt(), ::isDark) > 1000)
        // The gap under page 1 is background.
        val gapY = ((layout.pageRect(0).bottom + 4 - view.viewport.offsetY) * scale).toInt()
        if (gapY < h) assertTrue(isBackground(frame.pixel(w / 2, gapY)))
    }

    @Test
    fun tilesAtZoomMatchADirectRender() {
        val s = open(Fixtures.path(Fixtures.TEXT_200))
        val msg = create(s.handle)
        val view = onMain { api.view(msg.viewId) }
        val doc = store.get(s.handle)
        val layout = view.layout
        val prod = producer(msg)
        awaitComplete(view, 0)
        // Exact render-scale steps (1, 2, 4 px/pt) draw tiles 1:1; 2.7 is drawn from the next step down-sampled.
        for (scale in listOf(1.0, 2.0, 4.0, 2.7)) {
            val pr = layout.pageRect(37)
            // The token line of page 38, left part of the page.
            val v = Viewport(w, h, pr.left + 40, pr.top + 60, scale)
            val before = view.completeFrameCount
            setViewport(msg.viewId, v)
            awaitComplete(view, before)
            val frame = prod.settledFrame()
            val ref = reference(doc, layout, 37, v)
            val visibleBottom = minOf(h, ((pr.bottom - v.offsetY) * scale).toInt())
            val (mean, share) = diff(frame, ref, 0, 0, minOf(w, ((pr.right - v.offsetX) * scale).toInt()), visibleBottom)
            Log.i(HOM25_TAG, "zoom %.1f px/pt: mean diff %.2f, pixels off %.3f %%".format(scale, mean, share * 100))
            val exact = scale == 1.0 || scale == 2.0 || scale == 4.0
            assertTrue("scale $scale mean diff $mean", mean < if (exact) 2.0 else 12.0)
            assertTrue("scale $scale pixels off $share", share < if (exact) 0.005 else 0.08)
            assertTrue(frame.count(0, 0, w, visibleBottom, ::isDark) > 500)
            ref.recycle()
        }
        assertEquals(37L, api.state(msg.viewId).pageIndex)
    }

    @Test
    fun rotatedPageRendersLikeItsThumbnailAndHighlightsTheToken() {
        val s = open(Fixtures.path(Fixtures.MERGE_3))
        val msg = create(s.handle, page = 2)
        val view = onMain { api.view(msg.viewId) }
        val layout = view.layout
        awaitComplete(view, 0)
        val page = layout.pages[2]
        assertTrue(page.displayWidth > page.displayHeight)
        // Search the token and show the hit: the highlight must cover drawn (dark) token pixels.
        val result = awaitCall<PdfSearchResultMsg> { api.search(msg.viewId, PdfSearchOptionsMsg("HOM27M-P0003", false, 10), it) }.getOrThrow()
        val hit = result.hits.single()
        assertEquals(2L, hit.pageIndex)
        val pr = layout.pageRect(2)
        // The token runs down the right edge of the turned page: put it in view at 3 px/pt.
        val shown = page.toDisplay(hit.bounds.x, hit.bounds.y, hit.bounds.width, hit.bounds.height)
        val v = Viewport(w, h, pr.left + shown.left - 100 / 3.0, pr.top + shown.top - 100 / 3.0, 3.0)
        var before = view.completeFrameCount
        setViewport(msg.viewId, v)
        onMain { api.showSearchHit(msg.viewId, hit) }
        awaitComplete(view, before)
        val frame = producer(msg).settledFrame()
        val rect = v.toScreen(shown.offset(pr.left, pr.top))
        // On a page turned 90° the token runs top to bottom: a tall, narrow rect.
        assertTrue("rotated hit rect $rect", rect.height > rect.width)
        val x0 = rect.left.toInt()
        val y0 = rect.top.toInt()
        val x1 = rect.right.toInt()
        val y1 = rect.bottom.toInt()
        val area = (x1 - x0) * (y1 - y0)
        val highlighted = frame.count(x0, y0, x1, y1, ::isHighlight)
        Log.i(HOM25_TAG, "rotated hit bounds ${hit.bounds} rect $rect highlight in frame ${frame.count(0, 0, w, h, ::isHighlight)} centre px ${Integer.toHexString(frame.pixel((x0 + x1) / 2, (y0 + y1) / 2))}")
        val text = frame.count(x0, y0, x1, y1) { c -> Color.red(c) < 140 && Color.blue(c) < 100 }
        assertTrue("highlight $highlighted of $area", highlighted > area / 3)
        assertTrue("token glyphs under the highlight: $text", text > area / 40)
        // Outside the rect there is no highlight.
        assertEquals(0, frame.count(x1 + 40, y0, x1 + 200, y1, ::isHighlight))

        before = view.completeFrameCount
        onMain { api.clearSearch(msg.viewId) }
        awaitComplete(view, before)
        assertEquals(0, producer(msg).settledFrame().count(x0, y0, x1, y1, ::isHighlight))
    }

    @Test
    fun annotatedPageRendersWithoutTheGetPageAnnotationsCrash() {
        val s = open(Fixtures.path(Fixtures.ANNOTATED_2))
        val doc = store.get(s.handle)
        val msg = create(s.handle, page = 1)
        val view = onMain { api.view(msg.viewId) }
        awaitComplete(view, 0)
        val frame = producer(msg).settledFrame()
        assertTrue(frame.count(0, 0, w, h, ::isDark) > 500)
        val thumb = awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, 1, 600, 800), it) }.getOrThrow()
        assertTrue(thumb.png.isNotEmpty())
        // From API 35 annotations are drawn with RenderParams; that never needed the fallback.
        assertEquals(Build.VERSION.SDK_INT >= 35, doc.requirePlatform().annotationsEnabled)
        if (Build.VERSION.SDK_INT >= 35) {
            // The stamp's red "APPROVED" appearance is drawn on page 2.
            val red = BitmapFactory.decodeByteArray(thumb.png, 0, thumb.png.size).let { b ->
                var n = 0
                for (y in 0 until b.height step 2) for (x in 0 until b.width step 2) {
                    val c = b.getPixel(x, y)
                    if (Color.red(c) > 150 && Color.green(c) < 90 && Color.blue(c) < 90) n++
                }
                n
            }
            Log.i(HOM25_TAG, "annotated_2p page 2 red stamp pixels (API ${Build.VERSION.SDK_INT}): $red")
        }
    }

    @Test
    fun thumbnailsFitTheirBox() {
        val s = open(Fixtures.path(Fixtures.MERGE_3))
        for ((index, box) in listOf(0 to (200 to 200), 1 to (200 to 200), 2 to (300 to 100))) {
            val img = awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, index.toLong(), box.first.toLong(), box.second.toLong()), it) }.getOrThrow()
            assertTrue(img.widthPx <= box.first && img.heightPx <= box.second)
            assertTrue(img.widthPx == box.first.toLong() || img.heightPx == box.second.toLong())
            val bmp = BitmapFactory.decodeByteArray(img.png, 0, img.png.size)
            assertEquals(img.widthPx.toInt(), bmp.width)
            assertTrue(isWhite(bmp.getPixel(1, bmp.height - 2)))
        }
        // Page 3 is displayed landscape.
        val rotated = awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, 2, 400, 400), it) }.getOrThrow()
        assertTrue(rotated.widthPx > rotated.heightPx)
        assertCode("notFound", awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, 3, 100, 100), it) })
        assertCode("invalidArgument", awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, 0, 0, 100), it) })
        assertCode("invalidArgument", awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(s.handle, 0, 9000, 100), it) })
        assertCode("notFound", awaitCall<PdfImageMsg> { api.pageThumbnail(PdfThumbnailRequestMsg(777, 0, 100, 100), it) })
    }

    @Test
    fun resizeSurfaceCycleAndDispose() {
        val s = open(Fixtures.path(Fixtures.TEXT_200))
        val msg = create(s.handle)
        val view = onMain { api.view(msg.viewId) }
        val prod = producer(msg)
        awaitComplete(view, 0)
        // Resize (rotation to landscape).
        var before = view.completeFrameCount
        val layout = view.layout
        setViewport(msg.viewId, Viewport(h, w, 0.0, 0.0, layout.fitScale(h)))
        awaitComplete(view, before)
        val landscape = prod.settledFrame()
        assertEquals(h, landscape.width)
        assertEquals(w, landscape.height)
        // Flutter drops the surface in the background, then hands out a new one.
        prod.simulateCleanup()
        val frames = prod.frameCount
        setViewport(msg.viewId, Viewport(h, w, 0.0, 300.0, layout.fitScale(h)))
        Thread.sleep(400)
        assertEquals("no frames without a surface", frames, prod.frameCount)
        before = view.completeFrameCount
        prod.simulateAvailable()
        awaitComplete(view, before)
        assertTrue(prod.awaitFrame(frames).count(0, 0, h, w, ::isDark) > 200)
        // Dispose: texture released, the document stays open for its handle.
        onMain { api.disposeTextureView(msg.viewId) }
        assertTrue(prod.released)
        assertEquals(0, onMain { api.viewCount })
        Thread.sleep(200)
        val doc = store.get(s.handle)
        assertFalse(doc.closed)
        assertCode("notFound", runCatching { onMain { api.disposeTextureView(msg.viewId) } })
        assertCode("notFound", runCatching { onMain { api.state(msg.viewId) } })
    }

    @Test
    fun viewKeepsItsDocumentAfterTheHandleCloses() {
        val s = open(Fixtures.path(Fixtures.MERGE_3))
        val msg = create(s.handle)
        val view = onMain { api.view(msg.viewId) }
        awaitComplete(view, 0)
        val doc = store.remove(s.handle)!!
        threads.render.post { doc.release() }
        Thread.sleep(200)
        assertFalse(doc.closed)
        val before = view.completeFrameCount
        setViewport(msg.viewId, view.viewport.copy(offsetY = 900.0))
        awaitComplete(view, before)
        onMain { api.disposeTextureView(msg.viewId) }
        val deadline = System.currentTimeMillis() + 5000
        while (!doc.closed && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertTrue(doc.closed)
    }

    @Test
    fun nativeNavigationSelectionAndErrors() {
        val s = open(Fixtures.path(Fixtures.TEXT_200))
        val msg = create(s.handle, page = 10)
        assertEquals(10L, msg.state.pageIndex)
        onMain { api.goToPage(msg.viewId, 120) }
        assertEquals(120L, api.state(msg.viewId).pageIndex)
        val fit = api.state(msg.viewId).minScale
        onMain { api.setScale(msg.viewId, fit * 3) }
        assertEquals(fit * 3, api.state(msg.viewId).scale, 1e-9)
        onMain { api.setScale(msg.viewId, fit * 100) }
        assertEquals(fit * 8, api.state(msg.viewId).scale, 1e-9)
        onMain { api.zoomToFit(msg.viewId) }
        assertEquals(fit, api.state(msg.viewId).scale, 1e-9)
        onMain { api.setDisplayMode(msg.viewId, PdfDisplayModeMsg.TWO_UP_CONTINUOUS) }
        assertEquals(PdfDisplayModeMsg.CONTINUOUS, api.state(msg.viewId).displayMode)
        // Selection is not offered on Android.
        assertNull(onMain { api.selectedText(msg.viewId) })
        assertFalse(onMain { api.copySelection(msg.viewId) })
        onMain { api.clearSelection(msg.viewId) }

        assertCode("invalidArgument", runCatching { onMain { api.goToPage(msg.viewId, 200) } })
        assertCode("invalidArgument", runCatching { onMain { api.setTextureViewport(msg.viewId, PdfViewportMsg(0, 100, 0.0, 0.0, 1.0)) } })
        assertCode("invalidArgument", runCatching { onMain { api.setTextureViewport(msg.viewId, PdfViewportMsg(100, 100, 0.0, 0.0, Double.NaN)) } })
        assertCode("notFound", runCatching { onMain { api.goToPage(999, 0) } })
        assertCode("notFound", awaitCall<PdfTextureViewMsg> { api.createTextureView(PdfTextureViewRequestMsg(999, 100, 100, 0, PdfDisplayModeMsg.CONTINUOUS), it) })
        assertCode("invalidArgument", awaitCall<PdfTextureViewMsg> { api.createTextureView(PdfTextureViewRequestMsg(s.handle, 0, 100, 0, PdfDisplayModeMsg.CONTINUOUS), it) })
        val locked = open(Fixtures.encrypted.absolutePath)
        assertCode("passwordRequired", awaitCall<PdfTextureViewMsg> { api.createTextureView(PdfTextureViewRequestMsg(locked.handle, 100, 100, 0, PdfDisplayModeMsg.CONTINUOUS), it) })

        // Search through the view: a newer search cancels an older one.
        val first = awaitCall<PdfSearchResultMsg>(call = { cb ->
            api.search(msg.viewId, PdfSearchOptionsMsg("page", false, 100000), cb)
            api.search(msg.viewId, PdfSearchOptionsMsg("HOM27T-P0007", true, 10)) { }
        })
        if (first.isFailure) assertCode("cancelled", first)
        val hits = awaitCall<PdfSearchResultMsg> { api.search(msg.viewId, PdfSearchOptionsMsg("hom27t-p0007", false, 10), it) }.getOrThrow()
        assertEquals(6L, hits.hits.single().pageIndex)
        onMain { api.showSearchHit(msg.viewId, hits.hits.single()) }
        assertCode(
            "invalidArgument",
            runCatching { onMain { api.showSearchHit(msg.viewId, PdfSearchHitMsg(0, 400, 0, 1, "", 0, 1, PdfRectMsg(0.0, 0.0, 1.0, 1.0))) } },
        )
        onMain { api.cancelSearch(msg.viewId) }
    }

    @Test
    fun unlockedEncryptedFileRendersFromApi35() {
        assumeTrue(Build.VERSION.SDK_INT >= 35)
        val s = open(Fixtures.encrypted.absolutePath, Fixtures.USER_PASSWORD)
        val msg = create(s.handle)
        val view = onMain { api.view(msg.viewId) }
        awaitComplete(view, 0)
        assertTrue(producer(msg).settledFrame().count(0, 0, w, h, ::isDark) > 500)
    }
}
