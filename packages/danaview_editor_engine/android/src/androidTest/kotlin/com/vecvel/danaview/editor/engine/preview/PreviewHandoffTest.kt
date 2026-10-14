// OWNER: AND-10
//
// The PreviewBackend contract with a backend that draws on the Surface itself (AND-16's
// MultiPlayerBackend will), using [RecordingBackend]: Surface hand-off between the backend and the
// paused renderer (renderer detached before the backend attaches; paused edits take the Surface
// back lazily), exact-seek acks only on the exact frame with the 500 ms timeout, structural
// patches debounced to the backend (10 patches in 1 s -> at most 3 rebuilds; play flushes and
// waits for the rebuild), surface loss detaching both, end of playback, and seq/clock rules.

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewHandoffTest {
    private fun harness(name: String, backend: RecordingBackend): PreviewHarness =
        PreviewHarness(name, backend = { backend }).apply { open() }

    @Test
    fun theSurfaceMovesBetweenTheBackendAndThePausedRenderer() {
        val b = RecordingBackend()
        harness("and10_handoff", b).use { h ->
            assertEquals(PreviewSession.Owner.RENDERER, h.sync { h.session.owner })
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), PreviewPlans.box()), rev = 1))
            h.producer.awaitFrame(0)
            assertTrue(h.session.renderer.hasSurface)
            b.calls.clear()
            h.play()
            assertEquals(listOf("attach", "play:0"), b.calls.filter { it == "attach" || it.startsWith("play") })
            assertEquals(PreviewSession.Owner.BACKEND, h.sync { h.session.owner })
            assertFalse("renderer detached before the backend attached", h.session.renderer.hasSurface)
            b.show(5)
            h.pause()
            assertEquals(5L, h.sync { h.session.playhead })
            assertEquals("lazy: the backend keeps the Surface after pause", PreviewSession.Owner.BACKEND, h.sync { h.session.owner })
            // A paused edit takes the Surface back and draws the playhead frame.
            b.calls.clear()
            val n = h.producer.frameCount
            h.patch(PreviewPlans.upsert(1, PreviewPlans.box(cx = 400.0)))
            assertEquals(listOf("detach"), b.calls.filter { it == "detach" || it == "attach" })
            assertEquals(PreviewSession.Owner.RENDERER, h.sync { h.session.owner })
            val f = h.producer.awaitFrame(n)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 5).toInt(), FrameBarcode.decode(f.rgba, f.width, f.height))
            // An exact seek hands it to the backend again; after it settles the renderer prefetches k.
            b.calls.clear()
            val fetched = h.session.renderer.fetchCount
            val ack = h.seek(PreviewPlans.grid.timeOfFrame(40))
            assertEquals(40L, ack.displayedFrame)
            assertEquals(listOf("attach", "seek:40:true"), b.calls.filter { it == "attach" || it.startsWith("seek") })
            h.waitUntil("prefetch of frame 40") { h.session.renderer.fetchCount > fetched }
            val n2 = h.producer.frameCount
            h.patch(PreviewPlans.upsert(2, PreviewPlans.box(cx = 200.0)))
            val g = h.producer.awaitFrame(n2)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 40).toInt(), FrameBarcode.decode(g.rgba, g.width, g.height))
            assertEquals("no fetch needed after the prefetch", 0, h.session.lastRender?.fetched)
        }
    }

    @Test
    fun exactSeeksAckOnlyTheExactFrameOrTheFrameShownAfterTheTimeout() {
        val b = RecordingBackend().apply { holdSeeks = true }
        harness("and10_seekack", b).use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            var ack: SeekAckMsg? = null
            h.onPreview { h.session.seek(PreviewPlans.grid.timeOfFrame(30) + 7, true) { ack = it.getOrThrow() } }
            h.waitUntil("seek issued") { b.calls.any { it.startsWith("seek:30") } }
            h.onPreview { b.show(29) } // nearest frame first: not acked
            Thread.sleep(100)
            assertEquals(null, ack)
            h.onPreview { b.show(30) }
            h.waitUntil("ack") { ack != null }
            assertEquals(30L, ack!!.displayedFrame)
            assertEquals(PreviewPlans.grid.timeOfFrame(30), ack!!.displayedFrameTimeUs)
            // Timeout (500 ms): acked with the frame actually displayed.
            val t0 = System.nanoTime()
            val late = h.seek(PreviewPlans.grid.timeOfFrame(60))
            val ms = (System.nanoTime() - t0) / 1e6
            assertEquals(30L, late.displayedFrame)
            assertTrue("timeout ~500 ms ($ms)", ms in 450.0..2000.0)
            assertEquals(1, h.sync { h.session.seeks.timeouts })
        }
    }

    @Test
    fun structuralPatchesAreDebouncedToTheBackendAndPlayWaitsForTheRebuild() {
        val b = RecordingBackend().apply { rebuildDelayMs = 200 }
        harness("and10_debounce", b).use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            h.waitUntil("first rebuild") { b.rebuilds.get() == 1 }
            // 10 structural patches in 1 s, one every 100 ms (each moves the box in time: a t change
            // is structural); sent without waiting for their acks, like PlanSync during a drag.
            val acks = java.util.concurrent.ConcurrentHashMap<Long, Boolean>()
            val start = System.nanoTime()
            for (i in 0 until 10) {
                val box = PreviewPlans.box().copy(t0 = PreviewPlans.grid.timeOfFrame(i.toLong()))
                val bytes = com.vecvel.danaview.editor.engine.plan.PlanWriter.patchJson(PreviewPlans.upsert(1L + i, box)).toByteArray()
                h.onPreview { h.session.applyPatch(bytes) { r -> acks[1L + i + 1] = r.getOrThrow().structural } }
                val due = start + (i + 1) * 100_000_000L
                while (System.nanoTime() < due) Thread.sleep(1)
            }
            h.waitUntil("10 acks") { acks.size == 10 }
            assertTrue(acks.values.all { it })
            h.waitUntil("debounce idle", 3_000) { b.calls.lastOrNull()?.startsWith("rebuild:11") == true }
            Thread.sleep(400)
            val rebuilds = b.rebuilds.get() - 1
            assertTrue("10 patches in 1 s -> $rebuilds rebuilds (<= 3)", rebuilds in 1..3)
            // A structural patch right before play: play flushes it and waits for the rebuild.
            b.calls.clear()
            h.patch(PreviewPlans.upsert(11, PreviewPlans.box().copy(z = 50)))
            h.play()
            val order = b.calls.filter { it.startsWith("rebuild") || it.startsWith("play") }
            assertEquals(listOf("rebuild:12", "play:0"), order)
        }
    }

    @Test
    fun surfaceLossDetachesTheBackendAndEndOfPlaybackPausesWithTheSameSeq() {
        val b = RecordingBackend()
        harness("and10_backend_surface", b).use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val playSeq = h.play()
            b.calls.clear()
            val waited = h.producer.simulateCleanup()
            assertTrue(waited <= 500.0)
            assertTrue("backend detached", b.calls.contains("detach"))
            assertFalse(h.session.renderer.hasSurface)
            h.producer.simulateAvailable()
            h.waitUntil("backend reattached") { b.calls.contains("attach") && b.attached != null }
            // The backend reaches the end: paused on its last frame, clock with the play's seq.
            h.onPreview { b.show(PreviewPlans.FRAMES - 1) }
            h.onPreview { h.session.ended(PreviewPlans.FRAMES - 1) }
            h.waitUntil("ended") { h.clocks().any { !it.playing && it.seq == playSeq } }
            val end = h.clocks().last { it.seq == playSeq }
            assertEquals(PreviewPlans.grid.timeOfFrame(PreviewPlans.FRAMES - 1), end.timeUs)
            assertFalse(h.sync { h.session.playing })
            // Play from the end restarts at frame 0.
            b.calls.clear()
            h.play()
            assertTrue(b.calls.contains("play:0"))
            await<Long> { cb -> h.onPreview { h.session.pause(cb) } }
        }
    }
}
