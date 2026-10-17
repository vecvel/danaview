@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-03
//
// ThumbnailService on the emulator with the ENG-05 fixtures: every strip cell's barcode equals the
// sync frame closest to its slot time (the documented sync-frame tolerance), rotated sources are
// upright, stills and MKV/WebM work, cache hits are <= 20 ms, cancel stops a render before its next
// frame, and failures are typed. Miss and hit times are logged under DanaviewThumbsTest (emulator
// numbers; the low-tier device budget is QA-04's).

package com.vecvel.danaview.editor.engine.thumbs

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.ThumbnailService
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ThumbnailTileMsg
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeStatus
import com.vecvel.danaview.editor.engine.support.read
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ThumbnailServiceTest {
    companion object {
        private const val TAG = "DanaviewThumbsTest"
        private lateinit var ctx: EngineContext
        private lateinit var service: ThumbnailService
        private val ids = AtomicInteger()

        @BeforeClass
        @JvmStatic
        fun setUp() {
            val app = TestFixtures.targetContext.applicationContext
            ctx = EngineContext(app, EngineThreads.android())
            val cache = File(app.cacheDir, "thumbs-test/danaview/editor")
            val support = File(app.filesDir, "thumbs-test/danaview/editor")
            cache.deleteRecursively()
            ctx.installRoots(Paths.fromDart(cache.absolutePath, support.absolutePath))
            service = ctx.thumbnails
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            service.trim(CacheTrimLevelMsg.CLEAR_ALL)
            ctx.threads.shutdown()
        }
    }

    private fun request(name: String, intervalMs: Long, tile: Long, heightPx: Long, fingerprint: String = "fp-$name"): ThumbnailRequestMsg {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
        return ThumbnailRequestMsg(
            media = ResolvedMediaMsg(uri = file.absolutePath, fingerprint = fingerprint, isProxy = false),
            intervalMs = intervalMs, tileIndex = tile, heightPx = heightPx, framesPerTile = 8, proxy = false,
        )
    }

    private fun await(request: ThumbnailRequestMsg, priority: ThumbPriorityMsg = ThumbPriorityMsg.VISIBLE, id: String = "r${ids.incrementAndGet()}"): Pair<Result<ThumbnailTileMsg>, Long> {
        val result = AtomicReference<Result<ThumbnailTileMsg>>()
        val latch = CountDownLatch(1)
        val started = System.nanoTime()
        service.requestTile(id, request, priority) { result.set(it); latch.countDown() }
        assertTrue("tile answered", latch.await(60, TimeUnit.SECONDS))
        return result.get() to (System.nanoTime() - started) / 1_000_000
    }

    /** Sync-frame presentation times (µs) of the first video track, as Media3 reads them. */
    private fun syncTimesUs(name: String): List<Long> {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
        val extractor = MediaExtractorCompat(TestFixtures.targetContext)
        try {
            extractor.setDataSource(file.absolutePath)
            val track = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)!!.startsWith("video/")
            }
            extractor.selectTrack(track)
            val times = ArrayList<Long>()
            do {
                if (extractor.sampleTime < 0) break
                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) times.add(extractor.sampleTime)
            } while (extractor.advance())
            return times.sorted()
        } finally {
            extractor.release()
        }
    }

    /** ExoPlayer's CLOSEST_SYNC choice for [positionUs]: the nearer sync frame, the earlier on a tie. */
    private fun closestSync(sync: List<Long>, positionUs: Long): Long {
        val before = sync.lastOrNull { it <= positionUs } ?: sync.first()
        val after = sync.firstOrNull { it > positionUs } ?: return before
        return if (abs(positionUs - before) <= abs(after - positionUs)) before else after
    }

    /** The barcode of every cell of [tile]. */
    private fun cellBarcodes(tile: ThumbnailTileMsg): List<Int?> {
        val strip = BitmapFactory.decodeByteArray(tile.encoded, 0, tile.encoded.size)!!
        val w = tile.frameWidthPx.toInt()
        assertEquals(w * tile.frames.toInt(), strip.width)
        return (0 until tile.frames.toInt()).map { i ->
            val cell = Bitmap.createBitmap(strip, i * w, 0, w, strip.height)
            val reading = FrameBarcode.read(cell)
            if (reading.status == FrameBarcodeStatus.OK) reading.index else null
        }
    }

    private fun checkSyncFrames(name: String, fps: Double, intervalMs: Long, tile: Long, heightPx: Long) {
        val req = request(name, intervalMs, tile, heightPx)
        val (result, ms) = await(req)
        val strip = result.getOrThrow()
        val sync = syncTimesUs(name)
        val times = (0 until strip.frames).map { (tile * 8 + it) * intervalMs * 1000 }
        val expected = times.map { (closestSync(sync, it) * fps / 1_000_000.0 + 0.5).toInt() }
        val actual = cellBarcodes(strip)
        Log.i(TAG, "$name interval $intervalMs tile $tile: miss $ms ms, ${strip.frames} frames ${strip.frameWidthPx}x$heightPx, barcodes $actual (sync frames $expected)")
        assertEquals("$name barcodes are the closest sync frames", expected, actual)
        for ((i, t) in times.withIndex()) {
            val shownUs = closestSync(sync, t)
            assertTrue("frame within half a GOP of its slot", abs(shownUs - t) <= 1_000_000)
        }
    }

    @Test
    fun tileFramesAreTheClosestSyncFrames() {
        checkSyncFrames("frame_counter_1080p30.mp4", 30.0, intervalMs = 1000, tile = 0, heightPx = 360)
        checkSyncFrames("frame_counter_1080p30.mp4", 30.0, intervalMs = 600, tile = 1, heightPx = 360)
        checkSyncFrames("frame_counter_720p24.mp4", 24.0, intervalMs = 900, tile = 0, heightPx = 360)
        checkSyncFrames("clap_flash_av.mp4", 30.0, intervalMs = 750, tile = 0, heightPx = 360)
    }

    @Test
    fun tileShapeAndPartialLastTile() {
        val (result, _) = await(request("frame_counter_1080p30.mp4", intervalMs = 1500, tile = 0, heightPx = 180))
        val strip = result.getOrThrow()
        // 8 s file: slots 0, 1.5, ..., 7.5 s (6 frames), 9 and 10.5 s are past the end.
        assertEquals(6L, strip.frames)
        assertEquals(320L, strip.frameWidthPx)
        val bitmap = BitmapFactory.decodeByteArray(strip.encoded, 0, strip.encoded.size)
        assertEquals(1920, bitmap.width)
        assertEquals(180, bitmap.height)
        assertTrue("JPEG", strip.encoded[0] == 0xFF.toByte() && strip.encoded[1] == 0xD8.toByte())
    }

    @Test
    fun rotatedSourceIsUpright() {
        val (result, _) = await(request("rotated_90.mov", intervalMs = 1000, tile = 0, heightPx = 1280))
        val strip = result.getOrThrow()
        assertEquals(3L, strip.frames)
        assertEquals("portrait cells", 720L, strip.frameWidthPx)
        val sync = syncTimesUs("rotated_90.mov")
        val expected = (0 until 3).map { (closestSync(sync, it * 1_000_000L) * 30 / 1_000_000.0 + 0.5).toInt() }
        assertEquals("barcodes read upright", expected, cellBarcodes(strip))
    }

    @Test
    fun matroskaAndWebmTiles() {
        for (name in listOf("sample_h264_aac.mkv", "sample_vp9_opus.webm")) {
            val (result, ms) = await(request(name, intervalMs = 1000, tile = 0, heightPx = 360))
            val strip = result.getOrThrow()
            // 75 frames (3 s) of video; the container duration (audio included) may run a few ms
            // past 3 s, which adds the 3 s slot.
            assertTrue("$name frames ${strip.frames}", strip.frames in 3L..4L)
            assertEquals(640L, strip.frameWidthPx)
            val sync = syncTimesUs(name)
            val expected = (0 until strip.frames.toInt()).map { (closestSync(sync, it * 1_000_000L) * 25 / 1_000_000.0 + 0.5).toInt() }
            Log.i(TAG, "$name: miss $ms ms, ${strip.frames} frames, sync frames $expected")
            assertEquals(name, expected, cellBarcodes(strip))
        }
    }

    @Test
    fun stillImageIsOneFrame() {
        val (result, _) = await(request("still_4k.jpg", intervalMs = 1000, tile = 0, heightPx = 360))
        val strip = result.getOrThrow()
        assertEquals(1L, strip.frames)
        assertEquals(640L, strip.frameWidthPx)
        assertEquals(listOf(0), cellBarcodes(strip))
    }

    @Test
    fun cacheHitWithin20Ms() {
        val req = request("frame_counter_720p60.mp4", intervalMs = 1000, tile = 0, heightPx = 180, fingerprint = "fp-hit")
        val (first, missMs) = await(req)
        val miss = first.getOrThrow()
        val hits = ArrayList<Long>()
        repeat(30) {
            val started = System.nanoTime()
            val (again, _) = await(req)
            hits.add((System.nanoTime() - started) / 1_000)
            assertEquals(miss.frames, again.getOrThrow().frames)
            assertTrue(miss.encoded.contentEquals(again.getOrThrow().encoded))
        }
        hits.sort()
        val p50 = hits[hits.size / 2] / 1000.0
        val p90 = hits[hits.size * 9 / 10] / 1000.0
        Log.i(TAG, "frame_counter_720p60 tile: miss $missMs ms; hit p50 $p50 ms, p90 $p90 ms, max ${hits.last() / 1000.0} ms (emulator)")
        assertTrue("cache hit p90 $p90 ms <= 20 ms", p90 <= 20.0)
        assertTrue(DiskCache.stores(ctx.requirePaths()).thumbs.file(ThumbnailService.cacheKey(req), "dvth").isFile)
    }

    @Test
    fun cancelStopsARunningRenderBeforeItsNextFrame() {
        val req = request("frame_counter_1080p30.mp4", intervalMs = 100, tile = 3, heightPx = 360, fingerprint = "fp-cancel")
        val decoded = AtomicInteger()
        val id = "cancel-${ids.incrementAndGet()}"
        val renderDone = CountDownLatch(1)
        service.onFrameDecoded = { requestId, index ->
            if (requestId == id) {
                decoded.incrementAndGet()
                if (index == 0) service.cancel(id)
            }
        }
        try {
            val result = AtomicReference<Result<ThumbnailTileMsg>>()
            service.requestTile(id, req, ThumbPriorityMsg.VISIBLE) { result.set(it); renderDone.countDown() }
            assertTrue(renderDone.await(30, TimeUnit.SECONDS))
            val error = result.get().exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.cancelled, error.code)
            Thread.sleep(1500)
            assertEquals("the render stopped after its first frame", 1, decoded.get())
            assertTrue("nothing was cached", !DiskCache.stores(ctx.requirePaths()).thumbs.file(ThumbnailService.cacheKey(req), "dvth").exists())
        } finally {
            service.onFrameDecoded = null
        }
    }

    @Test
    fun cancelOfAPendingRequestAnswersAtOnce() {
        // Two renders keep both workers busy; the third request waits and is cancelled while pending.
        val busy = (0 until 2).map { i ->
            val latch = CountDownLatch(1)
            service.requestTile("busy-$i-${ids.incrementAndGet()}", request("frame_counter_720p48.mp4", 950L + i, 0, 360, "fp-busy-$i"), ThumbPriorityMsg.BACKGROUND) { latch.countDown() }
            latch
        }
        val result = AtomicReference<Result<ThumbnailTileMsg>>()
        val latch = CountDownLatch(1)
        val id = "pending-${ids.incrementAndGet()}"
        service.requestTile(id, request("frame_counter_720p25.mp4", 1000, 0, 360, "fp-pending"), ThumbPriorityMsg.PREFETCH) { result.set(it); latch.countDown() }
        val started = System.nanoTime()
        service.cancel(id)
        assertTrue(latch.await(1, TimeUnit.SECONDS))
        Log.i(TAG, "pending cancel answered in ${(System.nanoTime() - started) / 1_000_000} ms")
        val error = result.get().exceptionOrNull()
        assertTrue("cancelled or rendered before the cancel", error == null || (error as EngineException).code == EngineErrorCode.cancelled)
        busy.forEach { assertTrue(it.await(60, TimeUnit.SECONDS)) }
    }

    @Test
    fun reusedIdKeepsTheReplacedRenderCountedUntilItReturns() {
        // A render whose id is reused is cancelled but keeps its worker until its next frame. It must
        // stay counted: with it and its replacement running, a later request waits in the priority
        // queue (at most two renders, two decoder instances) instead of being handed to a worker.
        val dup = "dup-${ids.incrementAndGet()}"
        val x = "bg-${ids.incrementAndGet()}"
        val z = "vis-${ids.incrementAndGet()}"
        val holdOld = CountDownLatch(1)
        val holdNew = CountDownLatch(1)
        val holdZ = CountDownLatch(1)
        val oldBlocked = CountDownLatch(1)
        val newBlocked = CountDownLatch(1)
        val dupFrames = AtomicInteger()
        val order = java.util.Collections.synchronizedList(ArrayList<String>())
        service.onFrameDecoded = { requestId, index ->
            when (requestId) {
                dup -> if (index == 0) {
                    if (dupFrames.incrementAndGet() == 1) {
                        oldBlocked.countDown()
                        holdOld.await(30, TimeUnit.SECONDS)
                    } else {
                        newBlocked.countDown()
                        holdNew.await(30, TimeUnit.SECONDS)
                    }
                }
                x -> if (index == 0) order.add(requestId)
                z -> if (index == 0) {
                    order.add(requestId)
                    // Holds its worker so only a wrongly started third render could decode next.
                    holdZ.await(30, TimeUnit.SECONDS)
                }
            }
        }
        val answers = CountDownLatch(4)
        val results = java.util.concurrent.ConcurrentHashMap<String, Result<ThumbnailTileMsg>>()
        fun submit(key: String, id: String, req: ThumbnailRequestMsg, priority: ThumbPriorityMsg) =
            service.requestTile(id, req, priority) { results[key] = it; answers.countDown() }
        try {
            submit("old", dup, request("frame_counter_720p48.mp4", 900, 0, 240, "fp-dup-old"), ThumbPriorityMsg.VISIBLE)
            assertTrue("old render reached its first frame", oldBlocked.await(30, TimeUnit.SECONDS))
            submit("new", dup, request("frame_counter_720p24.mp4", 900, 0, 240, "fp-dup-new"), ThumbPriorityMsg.VISIBLE)
            assertTrue("replacement render reached its first frame", newBlocked.await(30, TimeUnit.SECONDS))
            submit("x", x, request("frame_counter_720p25.mp4", 900, 0, 240, "fp-dup-x"), ThumbPriorityMsg.BACKGROUND)
            submit("z", z, request("frame_counter_720p60.mp4", 900, 0, 240, "fp-dup-z"), ThumbPriorityMsg.VISIBLE)
            holdOld.countDown()
            val deadline = System.nanoTime() + 30_000_000_000
            while (order.isEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
            Thread.sleep(1000)
            assertEquals("only the visible request took the freed worker while the replacement still ran", listOf(z), order.toList())
            holdNew.countDown()
            holdZ.countDown()
            assertTrue("all four answered", answers.await(60, TimeUnit.SECONDS))
            assertEquals(EngineErrorCode.cancelled, (results["old"]!!.exceptionOrNull() as EngineException).code)
            listOf("new", "x", "z").forEach { assertTrue("$it rendered", results[it]!!.isSuccess) }
            assertEquals(listOf(z, x), order.toList())
        } finally {
            holdOld.countDown()
            holdNew.countDown()
            holdZ.countDown()
            service.onFrameDecoded = null
        }
    }

    @Test
    fun failuresAreTyped() {
        val missing = ThumbnailRequestMsg(
            media = ResolvedMediaMsg(uri = File(TestFixtures.targetContext.cacheDir, "nope/missing.mp4").absolutePath, fingerprint = "fp-missing", isProxy = false),
            intervalMs = 1000, tileIndex = 0, heightPx = 180, framesPerTile = 8, proxy = false,
        )
        val (gone, _) = await(missing)
        assertEquals(EngineErrorCode.mediaOffline, (gone.exceptionOrNull() as EngineException).code)
        val (afterEnd, _) = await(request("frame_counter_720p25.mp4", intervalMs = 1000, tile = 5, heightPx = 180))
        assertEquals(EngineErrorCode.internal, (afterEnd.exceptionOrNull() as EngineException).code)
    }
}
