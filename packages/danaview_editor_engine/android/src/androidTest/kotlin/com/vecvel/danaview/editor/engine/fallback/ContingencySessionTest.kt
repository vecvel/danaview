// OWNER: AND-16
//
// AND-10's playback acceptance list through AND-16's backend, end to end in a PreviewSession over
// the fake SurfaceProducer (AND-10's PreviewHarness, ENG-05's 720p24 counter: main shows source
// frame 10 + k at output frame k): the session opens on the contingency backend, paused edits go
// through AND-17's renderer and play/seek hand the Surface to the backend; exact seeks show the
// exact frame; playback never shows a wrong or out-of-order frame; a structural edit during
// playback re-plans only the changed slot; adaptive quality steps full → 1/2 → 1/4 under injected
// load and recovers; an export suspension releases every decoder; a surface loss during playback
// recovers with the main thread waiting <= 500 ms. Emulator numbers, logged under AND16.
// Timing (DV_PERF_STRICT, harness/PerfGate.kt): the frame-count minimum, the 500 ms main-thread
// latch and the 10 s-per-level quality recovery are device numbers that apply only with
// DV_PERF_STRICT=1; without it a non-vacuity minimum, a 4x latch floor and longer waits. Wrong,
// unreadable or out-of-order frames and the quality step-down order fail in both modes.

package com.vecvel.danaview.editor.engine.fallback

import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.harness.PerfGate
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.LoopMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.preview.PreviewHarness
import com.vecvel.danaview.editor.engine.preview.PreviewPlans
import com.vecvel.danaview.editor.engine.preview.PreviewSessionManager
import com.vecvel.danaview.editor.engine.preview.ProducedFrame
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.EngineStats
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class ContingencySessionTest {
    private fun config(liveBudget: Int? = 6) = ContingencyPreviewBackend.Config(
        liveBudget = liveBudget,
        effectAssets = EffectFixtures.assets,
        codecSelector = ExactFrames.softwareFirst,
    )

    private fun harness(name: String, config: ContingencyPreviewBackend.Config = config(), quality: PreviewQualityMsg = PreviewQualityMsg.FULL): PreviewHarness =
        PreviewHarness(name, backend = { ContingencyPreviewBackend(config) }).apply { open(quality) }

    private fun backend(h: PreviewHarness) = h.session.backend as ContingencyPreviewBackend

    private fun stats(h: PreviewHarness): EngineStats = await { cb -> backend(h).stats(cb) }

    private fun barcode(f: ProducedFrame): Int? = FrameBarcode.decode(f.rgba, f.width, f.height)

    /** Frames the producer receives for [ms]; their main barcodes (null = unreadable). */
    private fun watch(h: PreviewHarness, ms: Long, during: () -> Unit = {}): List<Int?> {
        val seen = ArrayList<Int?>()
        // Start once playback presents (a cold deck start takes 1–2 s on the emulator).
        val first = h.producer.awaitFrame(h.producer.frameCount, PerfGate.boundMs(15_000))
        seen += barcode(first)
        var last = first.index
        val t0 = System.currentTimeMillis()
        var ran = false
        while (System.currentTimeMillis() - t0 < ms) {
            val f = h.producer.frames.lastOrNull()
            if (f != null && f.index > last) {
                // Every frame since the last look (the producer keeps the last 16).
                for (x in h.producer.frames) if (x.index > last) seen += barcode(x)
                last = f.index
            }
            if (!ran && System.currentTimeMillis() - t0 > ms / 3) {
                ran = true
                during()
            }
            Thread.sleep(2)
        }
        return seen
    }

    private fun assertPlayback(seen: List<Int?>, what: String) {
        val min = PerfGate.atLeast(3, 1)
        assertTrue("$what: frames shown (${seen.size}, need $min, ${PerfGate.mode})", seen.size >= min)
        assertTrue("$what: never an unreadable or wrong frame: $seen", seen.all { it != null && it >= PreviewPlans.SOURCE_OFFSET && it < PreviewPlans.SOURCE_OFFSET + PreviewPlans.FRAMES })
        for (i in 1 until seen.size) assertTrue("$what: frames advance: $seen", seen[i]!! >= seen[i - 1]!!)
    }

    @Test
    fun theSessionPlaysPausesAndSeeksThroughTheContingencyBackend() {
        harness("and16_session").use { h ->
            assertEquals(ContingencyPreviewBackend.NAME, h.session.backend.name)
            assertTrue(h.session.backend.drawsOnSurface)
            assertTrue("PreviewSessionManager picks AND-16's backend", PreviewSessionManager.defaultBackend() is ContingencyPreviewBackend)
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), PreviewPlans.box()), rev = 1))
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), barcode(h.producer.awaitFrame(0)))
            val rnd = Random(16)
            val times = ArrayList<Double>()
            repeat(24) {
                val k = rnd.nextLong(0, PreviewPlans.FRAMES)
                val t0 = System.nanoTime()
                val ack = h.seek(PreviewPlans.grid.timeOfFrame(k))
                times += (System.nanoTime() - t0) / 1e6
                assertEquals(k, ack.displayedFrame)
                assertEquals("frame $k on screen", (PreviewPlans.SOURCE_OFFSET + k).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
            }
            Log.i(AND16_TAG, "session exact seek through AND-16 (emulator, 1 slot 720p24 → 640x360): ${Timings(times)}")
            h.seek(0)
            h.play()
            val seen = watch(h, 3_000)
            val pauseSeq = h.pause()
            assertPlayback(seen, "playback")
            Log.i(AND16_TAG, "session playback 3 s @24 fps (emulator): ${seen.size} frames on the producer of ~72")
            // Paused edit after playback: the renderer takes the Surface back and draws the playhead.
            val n = h.producer.frameCount
            h.patch(PreviewPlans.upsert(1, PreviewPlans.box(cx = 400.0)))
            val edited = h.producer.awaitFrame(n)
            val k = PreviewPlans.grid.frameIndexOf(h.clocks().last { it.seq == pauseSeq }.timeUs)
            assertEquals((PreviewPlans.SOURCE_OFFSET + k).toInt(), barcode(edited))
        }
    }

    @Test
    fun aStructuralEditDuringPlaybackReplansOnlyTheChangedSlot() {
        harness("and16_replan").use { h ->
            val pip = PausedPlans.media("pip#v", 20, 1, 0, PreviewPlans.FRAMES, 150, xf = PlanTransform(cx = 480.0, cy = 270.0, s = 0.3))
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), pip), rev = 1))
            h.producer.awaitFrame(0)
            h.play()
            Thread.sleep(500)
            val before = stats(h)
            var editAt = 0L
            val seen = watch(h, 2_500) {
                editAt = System.nanoTime()
                // Trim the PiP: slot 1 changes, slot 0 (main) must keep its decks.
                h.onPreview {
                    h.session.applyPatch(
                        com.vecvel.danaview.editor.engine.plan.PlanWriter.patchJson(
                            PreviewPlans.upsert(1, pip.copy(t1 = PreviewPlans.grid.timeOfFrame(60), map = listOf(pip.map[0].copy(t1 = PreviewPlans.grid.timeOfFrame(60), s1 = pip.map[0].s0 + PreviewPlans.grid.timeOfFrame(60))))),
                        ).toByteArray(),
                    ) { }
                }
            }
            h.pause()
            val after = stats(h)
            Log.i(AND16_TAG, "structural edit during playback (emulator): slots re-planned ${after.slotsReplanned - before.slotsReplanned}, re-plans ${after.replans - before.replans}, frames ${seen.size}")
            assertEquals("only the changed slot was re-planned", 1, after.slotsReplanned - before.slotsReplanned)
            assertPlayback(seen, "playback across the re-plan")
            assertTrue(editAt > 0)
        }
    }

    @Test
    fun adaptiveQualityStepsDownUnderLoadAndRecovers() {
        val cfg = config()
        harness("and16_quality", cfg, PreviewQualityMsg.AUTO).use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            cfg.injectedCompositeDelayMs = 90
            // Loop the whole plan: the governor needs continuous playback (2 s windows, 10 s clean).
            val loop = LoopMsg(0, PreviewPlans.grid.timeOfFrame(PreviewPlans.FRAMES))
            h.call<Long> { s, cb -> s.play(loop, cb) }
            h.waitUntil("half", PerfGate.boundMs(15_000)) { h.previewEvents(PreviewEventKindMsg.DEGRADED).any { it.quality == PreviewQualityMsg.HALF } }
            h.waitUntil("quarter", PerfGate.boundMs(15_000)) { h.previewEvents(PreviewEventKindMsg.DEGRADED).any { it.quality == PreviewQualityMsg.QUARTER } }
            h.waitUntil("quarter-size frames") { h.producer.last()?.width == 160 }
            cfg.injectedCompositeDelayMs = 0
            // Loop playback so the governor sees clean playback (10 s per step up).
            // Recovery: one level up per 10 s of clean playback (the emulator itself may drop more
            // than 10% in a window now and then, which restarts the 10 s).
            val full = runCatching {
                h.waitUntil("recovered to full", PerfGate.boundMs(60_000)) { h.previewEvents(PreviewEventKindMsg.DEGRADED).any { it.quality == PreviewQualityMsg.FULL } }
            }.isSuccess
            h.pause()
            val steps = h.previewEvents(PreviewEventKindMsg.DEGRADED).map { it.quality }
            Log.i(AND16_TAG, "adaptive quality under injected load (emulator): $steps (back to full: $full)")
            assertEquals(listOf(PreviewQualityMsg.HALF, PreviewQualityMsg.QUARTER), steps.take(2))
            // Recovery needs 10 s of clean playback per level, which a loaded emulator may never give:
            // required with DV_PERF_STRICT=1; without it, a recovery that happens must still go up
            // one level at a time (QUARTER -> HALF), never straight to FULL.
            if (PerfGate.strict) {
                assertTrue("recovered at least one level: $steps", steps.drop(2).firstOrNull() == PreviewQualityMsg.HALF)
            } else {
                assertTrue("a recovery steps up one level first: $steps", steps.drop(2).firstOrNull().let { it == null || it == PreviewQualityMsg.HALF })
            }
            assertTrue(h.previewEvents(PreviewEventKindMsg.FRAME_SIZE).any { it.width == 160L })
            val wantW = when (steps.last()) {
                PreviewQualityMsg.QUARTER -> 160
                PreviewQualityMsg.HALF -> 320
                else -> 640
            }
            h.waitUntil("frames at the last level's size") { h.producer.last()?.width == wantW }
        }
    }

    @Test
    fun anExportSuspensionReleasesEveryDecoder() {
        harness("and16_suspend").use { h ->
            h.manager.suspendTiers = DeviceTierMsg.entries.toSet()
            val pip = PausedPlans.media("pip#v", 20, 1, 0, PreviewPlans.FRAMES, 150, xf = PlanTransform(cx = 480.0, cy = 270.0, s = 0.3))
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), pip), rev = 1))
            h.producer.awaitFrame(0)
            h.play()
            Thread.sleep(500)
            assertTrue(stats(h).deckCount >= 4)
            h.manager.suspendForExport("job1")
            h.waitUntil("suspended") { h.sync { h.session.isSuspended && !h.session.playing } }
            h.waitUntil("decoders released") { stats(h).deckCount == 0 }
            assertEquals(EngineErrorCode.busy, (runCatching { h.play() }.exceptionOrNull() as EngineException).code)
            h.manager.resumeAfterExport("job1")
            h.waitUntil("resumed") { h.sync { !h.session.isSuspended } }
            h.play()
            val seen = watch(h, 2_000)
            h.pause()
            assertPlayback(seen, "playback after the export")
            assertTrue(stats(h).deckCount >= 4)
        }
    }

    @Test
    fun aSurfaceLossDuringPlaybackRecovers() {
        harness("and16_surface").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val before = h.producer.frameCount
            h.play()
            // The loss lands during playback: once playback presents (a cold deck start takes
            // 1–2 s on the emulator, longer when it is loaded), not after a fixed pause.
            h.producer.awaitFrame(before, PerfGate.boundMs(15_000))
            Thread.sleep(300)
            val gen = h.producer.generations
            val waited = h.producer.simulateCleanup()
            h.waitUntil("surfaceLost") { h.previewEvents(PreviewEventKindMsg.SURFACE_LOST).isNotEmpty() }
            Thread.sleep(200)
            h.producer.simulateAvailable()
            h.waitUntil("recovered") { h.previewEvents(PreviewEventKindMsg.RECOVERED).isNotEmpty() }
            val seen = watch(h, 1_200)
            h.pause()
            Log.i(AND16_TAG, "surface loss during contingency playback: main thread waited %.1f ms (emulator)".format(waited))
            val latchBound = PerfGate.bound(520.0)
            assertTrue("latch <= 500 ms ($waited, bound $latchBound, ${PerfGate.mode})", waited <= latchBound)
            assertEquals(0, h.session.bridge.latchTimeouts)
            assertTrue(h.producer.last()!!.generation > gen)
            assertPlayback(seen, "playback after the surface came back")
        }
    }
}
