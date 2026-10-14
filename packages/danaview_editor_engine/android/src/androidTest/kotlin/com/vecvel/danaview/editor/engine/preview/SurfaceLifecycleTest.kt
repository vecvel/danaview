// OWNER: AND-10
//
// resetInBackground surface lifecycle (ARCH §12.7): Flutter's SurfaceProducer calls
// onSurfaceCleanup on the main thread before it destroys the Surface; the session detaches and the
// main thread waits at most 500 ms; onSurfaceAvailable hands a new Surface that the session
// reattaches and redraws with the last frame (including edits made while the surface was gone).
// The fake producer closes its ImageReader right after cleanup returns, like Flutter does.

package com.vecvel.danaview.editor.engine.preview

import android.util.Log
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.Stats
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceLifecycleTest {
    @Test
    fun surfaceLossRecoversAndTheLatchStaysUnder500Ms() {
        PreviewHarness("and10_surface").use { h ->
            h.open()
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), PreviewPlans.box()), rev = 1))
            var shown = h.producer.awaitFrame(0)
            val waits = ArrayList<Double>()
            var rev = 1L
            for (cycle in 0 until 8) {
                val gen = h.producer.generations
                // Busy cycles: a cold seek (EXACT extraction + GL) is in flight when the cleanup comes.
                if (cycle % 2 == 1) h.onPreview { h.session.seek(PreviewPlans.grid.timeOfFrame(10L + cycle * 7), true) { } }
                waits += h.producer.simulateCleanup()
                h.waitUntil("surfaceLost") { h.previewEvents(PreviewEventKindMsg.SURFACE_LOST).size == cycle + 1 }
                // Edits while the surface is gone render offscreen and must show after recovery.
                if (cycle % 3 == 0) {
                    h.patch(PreviewPlans.upsert(rev, PreviewPlans.box(cx = 100.0 + cycle * 50)))
                    rev++
                }
                val n = h.producer.frameCount
                h.producer.simulateAvailable()
                val recovered = h.producer.awaitFrame(n)
                assertEquals("new surface generation", gen + 1, recovered.generation)
                h.waitUntil("recovered") { h.previewEvents(PreviewEventKindMsg.RECOVERED).size == cycle + 1 }
                val k = h.sync { h.session.playhead }
                // The redraw shows the current frame (the paused frame, or the frame the seek settled on).
                h.waitUntil("settled") { h.sync { !h.session.seeks.isBusy } }
                Thread.sleep(150)
                val now = h.producer.last()!!
                assertEquals("frame $k after recovery", (PreviewPlans.SOURCE_OFFSET + h.sync { h.session.playhead }).toInt(), FrameBarcode.decode(now.rgba, now.width, now.height))
                if (cycle % 3 == 0) assertTrue("the edit made while lost is shown", meanDiff(shown.rgba, recovered.rgba) > 0.5 || k != 0L)
                shown = now
            }
            val bridge = h.session.bridge
            Log.i(AND10_TAG, "onSurfaceCleanup main-thread wait (emulator): ${Stats(waits)}; bridge max ${"%.1f".format(bridge.maxLatchMs)} ms")
            assertEquals(8, bridge.latchCount)
            assertEquals("no latch timed out", 0, bridge.latchTimeouts)
            assertTrue("latch <= 500 ms (${bridge.maxLatchMs})", bridge.maxLatchMs <= 500.0)
            assertTrue(waits.all { it <= 520.0 })
        }
    }

    @Test
    fun theMainThreadNeverWaitsMoreThan500MsEvenWhenThePreviewLaneIsBlocked() {
        PreviewHarness("and10_latch").use { h ->
            h.open()
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            // Block danaview-preview for 1.5 s: the cleanup cannot run in time.
            h.onPreview { Thread.sleep(1_500) }
            Thread.sleep(50)
            val waited = h.producer.simulateCleanup()
            Log.i(AND10_TAG, "cleanup with a blocked preview lane waited ${"%.1f".format(waited)} ms (emulator)")
            assertTrue("bounded wait ($waited ms)", waited in 480.0..600.0)
            assertEquals(1, h.session.bridge.latchTimeouts)
            assertTrue(h.session.bridge.maxLatchMs <= 520.0)
            // The deferred detach still runs, and the session recovers on the next surface.
            h.waitUntil("surfaceLost") { h.previewEvents(PreviewEventKindMsg.SURFACE_LOST).isNotEmpty() }
            val n = h.producer.frameCount
            h.producer.simulateAvailable()
            val f = h.producer.awaitFrame(n)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), FrameBarcode.decode(f.rgba, f.width, f.height))
            // Paused edits work after recovery.
            val n2 = h.producer.frameCount
            h.patch(PreviewPlans.upsert(1, PreviewPlans.box()))
            assertTrue(meanDiff(f.rgba, h.producer.awaitFrame(n2).rgba) > 0.5)
            assertEquals(PausedPlans.W, f.width)
            assertEquals(PlanTransform.IDENTITY, PreviewPlans.main().xf)
        }
    }
}
