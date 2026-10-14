// OWNER: AND-17
//
// Paused edits through PausedFrameRenderer (D-36, ARCH §13.3 "Paused edits", §13.4), on the
// emulator (numbers logged under "AND17" are emulator measurements, never device numbers):
// - a param patch changing the effect of the SECONDARY sequence (the PiP on slot 1, the case
//   Media3's redraw misses, AND-01 V-N3) updates the paused frame, needs no new source frame, and
//   the new frame matches the Transformer export of the patched plan within §11.6 parity;
// - transient round trip after prefetch (snapshot swap -> frame swapped onto the surface): p50/p90;
// - a paused structural edit that adds a layer fetches only the new layer's frame; one that only
//   moves a layer in time fetches nothing; both timed;
// - editing modes: matte and cropSource change only their item's pixels; normal restores the frame;
// - cancel (play/seek) fails a pending render with `cancelled` and the next render works;
// - the frame is presented onto the attached Surface (ImageReader RGBA_8888) pixel-for-pixel equal
//   to the composed canvas, with pts = P(k);
// - surface hand-off with a player (the showSourceFrame mechanism): ExoPlayer renders into the
//   Surface, `clearVideoSurface(surface)` detaches it (the no-argument overload throws in Media3
//   1.11.1), the renderer attaches, draws and detaches, and the player renders into the same
//   Surface again after `setVideoSurface` + seek.

package com.vecvel.danaview.editor.engine.paused

import android.graphics.ImageFormat
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.TransientLayer
import com.vecvel.danaview.editor.engine.preview.PausedEditingMode
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class PausedEditTest {
    private val k = 6L

    @Test
    fun secondarySequenceEffectChangeUpdatesThePausedFrame() {
        val planA = PausedScenes.layered()
        val changedFx = PausedScenes.PIP_FX.copy(adj = PlanAdjust(exposure = -0.4, saturation = -1.0), lut = null)
        val planB = PausedScenes.layered(changedFx, rev = 2)
        val reference = PausedReference.composedFrames(planB, setOf(k), "secondary_effect")
        PausedHarness("and17_secondary", planA).use { h ->
            h.prefetch(k)
            h.render()
            val before = h.capture()
            h.setPlan(planB)
            val r = h.render()
            assertEquals("param patch: no new source frame", 0, r.fetched)
            assertEquals(2L, r.rev)
            val after = h.capture()
            // The PiP region changed; the main layer's region away from the PiP did not.
            val pipDiff = PausedReference.meanDiff(before.rgba, after.rgba, after.width, 420, 210, 520, 290)
            val mainDiff = PausedReference.meanDiff(before.rgba, after.rgba, after.width, 20, 60, 200, 200)
            Log.i(AND17_TAG, "secondary effect change: PiP region mean diff $pipDiff/255, main region $mainDiff/255; GL ${"%.1f".format(r.glMs)} ms, total ${"%.1f".format(r.totalMs)} ms (emulator)")
            assertTrue("PiP updated ($pipDiff)", pipDiff > 20)
            assertEquals("main untouched", 0.0, mainDiff, 0.0)
            val stats = PausedReference.parity(after.rgba, reference.getValue(k), after.width, after.height)
            Log.i(AND17_TAG, "secondary effect change parity vs export: $stats")
            assertTrue("after the patch $stats", stats.withinParity())
        }
    }

    @Test
    fun transientRoundTripAfterPrefetch() {
        val plan = PausedScenes.layered()
        PausedHarness("and17_transient", plan).use { h ->
            val reader = ImageReader.newInstance(PausedPlans.W, PausedPlans.H, PixelFormat.RGBA_8888, 3)
            val readerThread = HandlerThread("and17-reader").apply { start() }
            val frames = AtomicInteger()
            reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { frames.incrementAndGet() } }, Handler(readerThread.looper))
            try {
                val warm0 = System.nanoTime()
                await<Unit> { h.renderer.warmUp(it) }
                val warmMs = (System.nanoTime() - warm0) / 1e6
                await<Unit> { h.renderer.attachSurface(reader.surface, PausedPlans.W, PausedPlans.H, it) }
                h.prefetch(k)
                val first = h.render()
                Log.i(AND17_TAG, "warm-up (EGL + all programs) ${"%.1f".format(warmMs)} ms; first render after warm-up: GL ${"%.1f".format(first.glMs)} ms (emulator)")
                val total = ArrayList<Double>()
                val gl = ArrayList<Double>()
                val wall = ArrayList<Double>()
                repeat(40) { i ->
                    val t0 = System.nanoTime()
                    val tr = PlanTransient(item = "pip", layers = listOf(TransientLayer("pip#v", xf = PlanTransform(cx = 400.0 + i, cy = 240.0, s = 0.35 + i * 0.003, r = i.toDouble(), op = 0.9))))
                    h.snapshot.set(h.snapshot.get().withTransient(tr))
                    val r = h.render()
                    wall += (System.nanoTime() - t0) / 1e6
                    total += r.totalMs
                    gl += r.glMs
                    assertEquals(0, r.fetched)
                    assertTrue(r.presented)
                }
                val s = Stats(wall)
                Log.i(AND17_TAG, "transient round trip (snapshot swap -> swapped frame), emulator: wall $s; renderer total ${Stats(total)}; GL ${Stats(gl)}")
                // Emulator sanity bound only; the ≤ 2 frames on a mid device is QA-04's (deferred: no device).
                assertTrue("transient p50 ${s.p50} ms", s.p50 < 250)
                val deadline = System.currentTimeMillis() + 2_000
                while (frames.get() < 41 && System.currentTimeMillis() < deadline) Thread.sleep(10)
                assertTrue("frames reached the surface: ${frames.get()}", frames.get() >= 30)
                await<Unit> { h.renderer.detachSurface(it) }
            } finally {
                reader.close()
                readerThread.quitSafely()
            }
        }
    }

    @Test
    fun structuralEditsFetchOnlyNewlyNeededLayers() {
        val plan = PausedScenes.layered()
        PausedHarness("and17_structural", plan).use { h ->
            val pre = h.prefetch(k)
            Log.i(AND17_TAG, "prefetch of 2 layers at k=$k: ${"%.1f".format(pre.wallMs)} ms (emulator, cold extractor)")
            h.render()
            // Moving the band in time: structural, but no new picture.
            val moved = plan.copy(rev = 2, layers = plan.layers.map { if (it.id == "band#v") it.copy(t0 = PausedPlans.grid.timeOfFrame(2)) else it })
            h.setPlan(moved, setOf("band#v"))
            val r1 = h.render()
            assertEquals(0, r1.fetched)
            // Adding a layer of another source time: exactly one new EXACT frame.
            val added = PausedPlans.media("new#v", 10005, 2, 0, PausedPlans.FRAMES, 150, xf = PlanTransform(cx = 160.0, cy = 100.0, s = 0.3))
            val withNew = PausedPlans.plan(moved.layers + added, rev = 3)
            val times = ArrayList<Double>()
            h.setPlan(withNew, setOf("new#v"))
            val r2 = h.render()
            assertEquals("one newly needed frame", 1, r2.fetched)
            assertEquals(4, r2.drawn)
            times += r2.totalMs
            // Same structural add again at other source times (warm renderer): emulator numbers.
            for ((i, sf) in listOf(160L, 170L, 180L, 190L).withIndex()) {
                val next = PausedPlans.plan(moved.layers + added.copy(map = PausedPlans.media("new#v", 10005, 2, 0, PausedPlans.FRAMES, sf).map), rev = 4L + i)
                h.setPlan(next, setOf("new#v"))
                val r = h.render()
                assertEquals(1, r.fetched)
                times += r.totalMs
            }
            Log.i(AND17_TAG, "paused structural edit (one new EXACT extraction) -> frame, emulator: ${Stats(times)}; first ${"%.1f".format(times.first())} ms; time-only structural edit ${"%.1f".format(r1.totalMs)} ms")
            val got = h.capture()
            assertEquals("main still shows its rule frame", (10 + k).toInt(), FrameBarcode.decode(got.rgba, got.width, got.height))
        }
    }

    @Test
    fun editingModesChangeOnlyTheirItem() {
        val keyed = PausedScenes.layered(PausedScenes.PIP_FX.copy(chroma = PlanChroma(key = 0x808080, sim = 0.3)))
        // The main layer at half size with a centre crop, so the uncropped source shows around it.
        val plan = keyed.copy(layers = keyed.layers.map { if (it.id == "main#v") it.copy(crop = PlanCrop(0.2, 0.2, 0.8, 0.8), xf = PlanTransform(s = 0.5)) else it })
        PausedHarness("and17_modes", plan).use { h ->
            h.prefetch(k)
            h.render()
            val normal = h.capture()
            h.renderer.setEditingMode(PausedEditingMode.Matte("pip"))
            assertEquals(0, h.render().fetched)
            val matte = h.capture()
            assertTrue("matte changes the PiP", PausedReference.meanDiff(normal.rgba, matte.rgba, normal.width, 430, 220, 510, 280) > 5)
            assertEquals("matte leaves the main layer", 0.0, PausedReference.meanDiff(normal.rgba, matte.rgba, normal.width, 20, 60, 200, 200), 0.0)
            h.renderer.setEditingMode(PausedEditingMode.CropSource("main"))
            h.render()
            val crop = h.capture()
            // Main's cropped box: x 160..480, y 90..270; uncropped it grows to x 53..587, y 0..360.
            val ring = PausedReference.meanDiff(normal.rgba, crop.rgba, normal.width, 70, 100, 150, 230)
            val inner = PausedReference.meanDiff(normal.rgba, crop.rgba, normal.width, 200, 120, 300, 240)
            Log.i(AND17_TAG, "cropSource: outside-crop ring mean diff $ring/255, inside the crop $inner/255")
            assertTrue("cropSource shows the source outside the crop ($ring)", ring > 5)
            // Resampled on another raster grid (and sharpened), so not bit-equal; a 1 px shift of this
            // sharp content would differ by tens of levels.
            assertTrue("cropSource keeps the cropped region in place ($inner)", inner < 4.0)
            h.renderer.setEditingMode(PausedEditingMode.Normal)
            h.render()
            assertArrayEquals("normal restores the frame", normal.rgba, h.capture().rgba)
        }
    }

    @Test
    fun cancelFailsPendingWorkAndRenderingContinues() {
        PausedHarness("and17_cancel", PausedScenes.layered()).use { h ->
            h.renderer.setFrame(3)
            val latch = CountDownLatch(1)
            var error: Throwable? = null
            h.renderer.render { r ->
                error = r.exceptionOrNull()
                latch.countDown()
            }
            h.renderer.cancel()
            assertTrue(latch.await(60, TimeUnit.SECONDS))
            val e = error
            if (e != null) assertEquals(EngineErrorCode.cancelled, (e as EngineException).code)
            val r = h.render()
            assertEquals(3L, r.k)
            assertEquals(0, r.missing)
        }
    }

    @Test
    fun frameIsPresentedOntoTheAttachedSurface() {
        PausedHarness("and17_present", PausedScenes.layered()).use { h ->
            val reader = ImageReader.newInstance(PausedPlans.W, PausedPlans.H, PixelFormat.RGBA_8888, 2)
            val images = LinkedBlockingQueue<Pair<Long, ByteArray>>()
            val thread = HandlerThread("and17-present").apply { start() }
            reader.setOnImageAvailableListener({ r ->
                r.acquireLatestImage()?.use { img ->
                    val plane = img.planes[0]
                    val buf = plane.buffer
                    val out = ByteArray(img.width * img.height * 4)
                    for (y in 0 until img.height) {
                        buf.position(y * plane.rowStride)
                        buf.get(out, y * img.width * 4, img.width * 4)
                    }
                    images += img.timestamp to out
                }
            }, Handler(thread.looper))
            try {
                assertFalse(h.renderer.hasSurface)
                await<Unit> { h.renderer.attachSurface(reader.surface, PausedPlans.W, PausedPlans.H, it) }
                assertTrue(h.renderer.hasSurface)
                h.prefetch(k)
                val r = h.render()
                assertTrue(r.presented)
                val (ts, pixels) = checkNotNull(images.poll(10, TimeUnit.SECONDS)) { "no frame on the surface" }
                assertEquals("pts = P(k) in ns", PausedPlans.grid.platformTimeOfFrame(k) * 1000, ts)
                assertArrayEquals("surface = composed canvas", h.capture().rgba, pixels)
                // Re-present after a detach/attach without recomposing.
                await<Unit> { h.renderer.detachSurface(it) }
                assertFalse(h.renderer.hasSurface)
                await<Unit> { h.renderer.attachSurface(reader.surface, PausedPlans.W, PausedPlans.H, it) }
                assertTrue(await<Boolean> { h.renderer.present(it) })
                assertNotNull(images.poll(10, TimeUnit.SECONDS))
                await<Unit> { h.renderer.detachSurface(it) }
            } finally {
                reader.close()
                thread.quitSafely()
            }
        }
    }

    @OptIn(UnstableApi::class)
    @Test
    fun surfaceHandsOffBetweenPlayerAndRenderer() {
        PausedHarness("and17_handoff", PausedScenes.layered()).use { h ->
            val reader = ImageReader.newInstance(PausedPlans.W, PausedPlans.H, ImageFormat.PRIVATE, 4, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
            val readerThread = HandlerThread("and17-handoff-reader").apply { start() }
            val frames = AtomicInteger()
            reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { frames.incrementAndGet() } }, Handler(readerThread.looper))
            val playerThread = HandlerThread("and17-player").apply { start() }
            val playerHandler = Handler(playerThread.looper)
            var player: ExoPlayer? = null
            val firstFrames = AtomicInteger()
            fun onPlayer(block: () -> Unit) {
                val latch = CountDownLatch(1)
                playerHandler.post {
                    try {
                        block()
                    } finally {
                        latch.countDown()
                    }
                }
                assertTrue(latch.await(30, TimeUnit.SECONDS))
            }
            fun waitFrames(atLeast: Int, what: String) {
                val deadline = System.currentTimeMillis() + 20_000
                while (frames.get() < atLeast && System.currentTimeMillis() < deadline) Thread.sleep(20)
                assertTrue("$what: ${frames.get()} < $atLeast", frames.get() >= atLeast)
            }
            try {
                onPlayer {
                    player = ExoPlayer.Builder(TestFixtures.targetContext).setLooper(playerThread.looper).build().apply {
                        setSeekParameters(SeekParameters.EXACT)
                        addListener(object : Player.Listener {
                            override fun onRenderedFirstFrame() {
                                firstFrames.incrementAndGet()
                            }
                        })
                        setVideoSurface(reader.surface)
                        setMediaItem(MediaItem.fromUri(Uri.parse(PausedPlans.uri("frame_counter_720p24.mp4"))))
                        prepare()
                        seekTo(1_000)
                    }
                }
                waitFrames(1, "player frame")
                // Pause and detach the player from this Surface (never the no-argument overload).
                onPlayer {
                    player!!.pause()
                    player!!.clearVideoSurface(reader.surface)
                }
                val beforeRenderer = frames.get()
                await<Unit> { h.renderer.attachSurface(reader.surface, PausedPlans.W, PausedPlans.H, it) }
                h.prefetch(k)
                assertTrue(h.render().presented)
                waitFrames(beforeRenderer + 1, "renderer frame")
                await<Unit> { h.renderer.detachSurface(it) }
                // Play/seek: the player takes the Surface back and renders into it again.
                val beforePlayer = frames.get()
                val firstBefore = firstFrames.get()
                onPlayer {
                    player!!.setVideoSurface(reader.surface)
                    player!!.seekTo(2_000)
                }
                waitFrames(beforePlayer + 1, "player frame after reattach")
                val deadline = System.currentTimeMillis() + 10_000
                while (firstFrames.get() == firstBefore && System.currentTimeMillis() < deadline) Thread.sleep(20)
                assertTrue("player rendered again", firstFrames.get() > firstBefore)
            } catch (t: Throwable) {
                if (t is AssertionError) throw t
                fail("hand-off failed: $t")
            } finally {
                onPlayer { player?.release() }
                playerThread.quitSafely()
                reader.close()
                readerThread.quitSafely()
            }
        }
    }

    @Test
    fun rendererRefusesWorkAfterDispose() {
        val h = PausedHarness("and17_disposed", PausedScenes.layered())
        h.prefetch(1)
        h.render()
        h.close()
        try {
            h.render()
            fail("render after dispose")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.cancelled, e.code)
        }
        assertTrue(h.renderer.renderCount >= 1)
    }
}
