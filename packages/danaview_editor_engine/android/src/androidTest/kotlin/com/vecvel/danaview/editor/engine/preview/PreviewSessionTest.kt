// OWNER: AND-10
//
// PreviewSession end to end on the emulator with the built-in StillFramesBackend, installed
// explicitly (since AND-16 the manager's default backend is ContingencyPreviewBackend, whose
// session-level tests are AND-16's ContingencySessionTest): the real PausedFrameRenderer draws onto a fake SurfaceProducer's
// ImageReader, so every presented frame is checked by its barcode (ENG-05's 720p24 counter, frame
// number = source frame). Covers: open → firstFrame; paused edits through AND-17 (param patch,
// transient, clear, editing mode, refresh); "a rebuild keeps the last frame"; seq semantics of
// play/pause/seek and the clock; exact seeks and scrubs; stills playback (drops, never a wrong
// frame); quality resize; auto quality back at the requested level when playback stops (QA-05 D11,
// also with [RecordingBackend]: pause, end of the plan, thermally capped to half); export
// suspension; look stills, colour samples, source frames; dispose.
// Times are emulator numbers (logged under AND10), never device numbers.

package com.vecvel.danaview.editor.engine.preview

import android.graphics.BitmapFactory
import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.Stats
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.pigeon.LookSpecMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PatchSet
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch
import com.vecvel.danaview.editor.engine.plan.TransientLayer
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.random.Random

/** 640×360 @ 24 fps plans over the counter: main shows source frame 10 + k at output frame k. */
object PreviewPlans {
    const val FRAMES = 96L
    const val SOURCE_OFFSET = 10L
    val grid: FrameGrid = FrameGrid.of(PausedPlans.FPS)

    fun plan(layers: List<PlanLayer>, rev: Long, frames: Long = FRAMES): RenderPlan {
        val p = RenderPlan(
            rev = rev, target = PlanTarget.PREVIEW, canvas = PlanCanvas(PausedPlans.W, PausedPlans.H, PausedPlans.FPS, bg = 0xFF203040.toInt()),
            durUs = grid.timeOfFrame(frames), assets = PausedPlans.assets(), layers = layers.sortedWith(PlanValidator::compareLayers), audio = emptyList(),
        )
        assertEquals("plan valid", emptyList<Any>(), PlanValidator.validate(p))
        return p
    }

    fun main(): PlanLayer = PausedPlans.media("main#v", 10, 0, 0, FRAMES, SOURCE_OFFSET)

    fun box(cx: Double = 120.0, color: Int = 0xFFFF2020.toInt(), z: Int = 30): PlanLayer = PlanLayer(
        id = "box#v", z = z, t0 = 0, t1 = grid.timeOfFrame(FRAMES), kind = PlanLayerKind.SOLID, color = color,
        base = PlanSize(80.0, 60.0), xf = PlanTransform(cx = cx, cy = 100.0),
    )

    fun upsert(from: Long, vararg layers: PlanLayer) = RenderPlanPatch(from = from, to = from + 1, layers = PatchSet(upsert = layers.toList()))
}

class PreviewSessionTest {
    private fun barcode(frame: ProducedFrame): Int? = FrameBarcode.decode(frame.rgba, frame.width, frame.height)

    private fun opened(name: String, quality: PreviewQualityMsg = PreviewQualityMsg.FULL): PreviewHarness =
        PreviewHarness(name, backend = { StillFramesBackend() }).apply { open(quality) }

    @Test
    fun openShowsTheFirstFrameAndPausedEditsGoThroughThePausedRenderer() {
        opened("and10_paused").use { h ->
            assertEquals(TextureRegistryLifecycle.RESET_IN_BACKGROUND, h.producer.lifecycle.name)
            assertEquals(h.producer.id(), h.opened.textureId)
            assertEquals("stills", h.session.backend.name)
            val before = h.producer.frameCount
            val ack = h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), PreviewPlans.box()), rev = 1))
            assertEquals(1L, ack.rev)
            assertTrue(ack.structural)
            val first = h.producer.awaitFrame(before)
            assertEquals(640, first.width)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), barcode(first))
            h.waitUntil("firstFrame") { h.previewEvents(PreviewEventKindMsg.FIRST_FRAME).isNotEmpty() }
            assertEquals(640L, h.previewEvents(PreviewEventKindMsg.FIRST_FRAME).single().width)
            Log.i(AND10_TAG, "setPlan -> first frame: ${ack.applyMs} ms (emulator, cold extraction)")

            // Param patch: one GL pass through the paused renderer, nothing fetched.
            val renders = h.session.renderer.renderCount
            val n1 = h.producer.frameCount
            val moved = h.patch(PreviewPlans.upsert(1, PreviewPlans.box(cx = 500.0)))
            assertFalse(moved.structural)
            assertEquals(2L, moved.rev)
            val f1 = h.producer.awaitFrame(n1)
            assertTrue(h.session.renderer.renderCount > renders)
            assertEquals(0, h.session.lastRender?.fetched)
            assertTrue("the box moved", meanDiff(first.rgba, f1.rgba) > 1.0)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), barcode(f1))

            // Transients: latest state drawn; clearing restores the committed frame exactly.
            val times = ArrayList<Double>()
            var last = f1
            for (i in 1..12) {
                val n = h.producer.frameCount
                val t0 = System.nanoTime()
                h.transient(PlanTransient(item = "box", layers = listOf(TransientLayer("box#v", xf = PlanTransform(cx = 500.0 - i * 20, cy = 100.0 + i * 10)))))
                last = h.producer.awaitFrame(n)
                times += (last.atNs - t0) / 1e6
            }
            assertTrue(meanDiff(f1.rgba, last.rgba) > 1.0)
            Log.i(AND10_TAG, "transient -> frame on the producer, paused (emulator): ${Stats(times)}")
            val n2 = h.producer.frameCount
            h.onPreview { h.session.clearTransient("box") }
            val cleared = h.producer.awaitFrame(n2)
            assertEquals("cleared transient restores the committed frame", 0.0, meanDiff(f1.rgba, cleared.rgba), 0.5)

            // Editing mode (cropSource of a cropped main) and refresh go through the renderer too.
            h.patch(RenderPlanPatch(from = 2, to = 3, layers = PatchSet(upsert = listOf(PreviewPlans.main().copy(crop = PlanCrop(0.2, 0.2, 0.8, 0.8), xf = PlanTransform(s = 0.5))))))
            val n3 = h.producer.frameCount
            val beforeMode = requireNotNull(h.producer.last())
            h.call<Unit> { s, cb -> s.setEditingMode(EditingModeMsg(EditingModeKindMsg.CROP_SOURCE, "main"), cb) }
            val crop = h.producer.awaitFrame(n3)
            assertTrue("cropSource shows the uncropped source", meanDiff(beforeMode.rgba, crop.rgba) > 1.0)
            h.call<Unit> { s, cb -> s.setEditingMode(EditingModeMsg(EditingModeKindMsg.NORMAL), cb) }
            val r = h.session.renderer.renderCount
            h.call<Unit> { s, cb -> s.refresh(cb) }
            assertTrue(h.session.renderer.renderCount > r)

            // debugCaptureFrame = the frame on the producer (main restored to full frame first).
            h.patch(RenderPlanPatch(from = 3, to = 4, layers = PatchSet(upsert = listOf(PreviewPlans.main()))))
            val cap = h.capture()
            val onProducer = requireNotNull(h.producer.last())
            assertEquals(0.0, meanDiff(cap, onProducer.rgba), 0.5)
            assertEquals(640 * 360 * 4, cap.size)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), FrameBarcode.decode(cap, 640, 360))
        }
    }

    @Test
    fun planErrorsAreTyped() {
        opened("and10_errors").use { h ->
            val e1 = runCatching { h.patch(PreviewPlans.upsert(1, PreviewPlans.box())) }.exceptionOrNull() as EngineException
            assertEquals("patch before any plan", EngineErrorCode.planOutOfSync, e1.code)
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 5))
            val e2 = runCatching { h.patch(PreviewPlans.upsert(4, PreviewPlans.box())) }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.planOutOfSync, e2.code)
            val e3 = runCatching { h.call<Any> { s, cb -> s.setPlan("{\"v\":1".toByteArray(), cb) } }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.planInvalid, e3.code)
            // A layer outside the plan duration is a validator error (ARCH §11.3).
            val bad = PreviewPlans.box().copy(t1 = PreviewPlans.grid.timeOfFrame(PreviewPlans.FRAMES + 50))
            val e4 = runCatching { h.patch(PreviewPlans.upsert(5, bad)) }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.planInvalid, e4.code)
            // The session still works.
            assertEquals(6L, h.patch(PreviewPlans.upsert(5, PreviewPlans.box())).rev)
        }
    }

    @Test
    fun aStructuralRebuildKeepsTheLastFrame() {
        opened("and10_rebuild").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            val shown = h.producer.awaitFrame(0)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), barcode(shown))
            // Add a PiP of another source time: one cold EXACT extraction before the new frame.
            val n = h.producer.frameCount
            val pip = PausedPlans.media("pip#v", 20, 1, 0, PreviewPlans.FRAMES, 150, xf = PlanTransform(cx = 480.0, cy = 90.0, s = 0.3))
            val ack = h.patch(PreviewPlans.upsert(1, pip))
            assertTrue(ack.structural)
            val after = h.producer.awaitFrame(n)
            // Exactly one new frame was presented for the rebuild (no blank or intermediate frame),
            // and until then the producer kept the previous one.
            Thread.sleep(300)
            assertEquals("one present for the structural edit", n + 1, h.producer.frameCount)
            assertEquals(PreviewPlans.SOURCE_OFFSET.toInt(), barcode(after))
            assertTrue(meanDiff(shown.rgba, after.rgba) > 1.0)
            Log.i(AND10_TAG, "paused structural edit (new layer, cold EXACT extraction) -> frame: ${ack.applyMs} ms (emulator)")
        }
    }

    @Test
    fun exactSeeksShowTheExactFrameAndScrubsReportWhatTheyShow() {
        opened("and10_seek").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val rnd = Random(10)
            val times = ArrayList<Double>()
            var lastSeq = 0L
            repeat(24) {
                val k = rnd.nextLong(0, PreviewPlans.FRAMES)
                val t = PreviewPlans.grid.timeOfFrame(k) + rnd.nextLong(0, 40_000).coerceAtMost(41_000)
                val expected = PreviewPlans.grid.frameIndexOf(t)
                val t0 = System.nanoTime()
                val ack = h.seek(t)
                times += (System.nanoTime() - t0) / 1e6
                assertEquals("seek to $t", expected, ack.displayedFrame)
                assertEquals(PreviewPlans.grid.timeOfFrame(expected), ack.displayedFrameTimeUs)
                assertEquals(t, ack.requestedUs)
                assertTrue("seq increases", ack.seq > lastSeq)
                lastSeq = ack.seq
                val cap = h.capture()
                assertEquals("frame $expected on screen", (PreviewPlans.SOURCE_OFFSET + expected).toInt(), FrameBarcode.decode(cap, 640, 360))
            }
            Log.i(AND10_TAG, "exact seek through StillFramesBackend (paused-exact stills, not AND-16), emulator: ${Stats(times)}")
            // Past the end clamps to the last frame.
            assertEquals(PreviewPlans.FRAMES - 1, h.seek(60_000_000).displayedFrame)
            // A burst of scrubs: every ack reports a frame that was shown; the last one is on screen.
            val acks = (0 until 6).map { i ->
                await<com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg> { cb -> h.onPreview { h.session.seek(PreviewPlans.grid.timeOfFrame(20L + i * 5), false, cb) } }
            }
            for (a in acks) assertTrue(a.displayedFrame in 0 until PreviewPlans.FRAMES)
            val final = h.seek(PreviewPlans.grid.timeOfFrame(45))
            assertEquals(45L, final.displayedFrame)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 45).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
        }
    }

    @Test
    fun seqSemanticsOfPlayPauseSeekAndTheClock() {
        opened("and10_seq").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val playSeq = h.play()
            assertEquals(1L, playSeq)
            h.waitUntil("a playing sample") { h.clocks().any { it.seq == playSeq && it.playing } }
            Thread.sleep(700)
            val pauseSeq = h.pause()
            assertEquals(2L, pauseSeq)
            val seekAck = h.seek(PreviewPlans.grid.timeOfFrame(30))
            assertEquals(3L, seekAck.seq)
            val play2 = h.play()
            assertEquals(4L, play2)
            Thread.sleep(300)
            val pause2 = h.pause()
            assertEquals(5L, pause2)
            Thread.sleep(400) // let trailing samples arrive
            val clocks = h.clocks()
            // Samples never go back in seq; a sample's state matches the command it reflects.
            for (i in 1 until clocks.size) assertTrue("seq order", clocks[i].seq >= clocks[i - 1].seq)
            assertTrue(clocks.filter { it.seq == pauseSeq || it.seq == pause2 }.none { it.playing })
            assertTrue(clocks.filter { it.seq == playSeq }.all { it.playing })
            val atSeek = clocks.filter { it.seq == seekAck.seq }
            assertTrue(atSeek.isNotEmpty())
            assertTrue(atSeek.all { !it.playing && it.timeUs == seekAck.displayedFrameTimeUs })
            // Every clock time is a frame time (D-35).
            for (c in clocks) assertEquals(c.timeUs, PreviewPlans.grid.timeOfFrame(PreviewPlans.grid.frameIndexOf(c.timeUs)))
            // The paused frame on screen is the playhead.
            val last = clocks.last()
            val k = PreviewPlans.grid.frameIndexOf(last.timeUs)
            assertEquals((PreviewPlans.SOURCE_OFFSET + k).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
        }
    }

    @Test
    fun stillsPlaybackDropsFramesButNeverShowsAWrongOne() {
        opened("and10_play").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val before = h.producer.frameCount
            val t0 = System.nanoTime()
            h.play()
            val seen = ArrayList<Int>()
            var lastIndex = before
            while ((System.nanoTime() - t0) / 1e6 < 3_000) {
                val f = h.producer.frames.lastOrNull()
                if (f != null && f.index > lastIndex) {
                    lastIndex = f.index
                    seen += barcode(f) ?: -1
                }
                Thread.sleep(2)
            }
            h.pause()
            assertTrue("frames were shown", seen.size >= 2)
            assertTrue("no undecodable or wrong frame: $seen", seen.all { it >= PreviewPlans.SOURCE_OFFSET && it < PreviewPlans.SOURCE_OFFSET + PreviewPlans.FRAMES })
            for (i in 1 until seen.size) assertTrue("frames advance: $seen", seen[i] >= seen[i - 1])
            Log.i(AND10_TAG, "StillFramesBackend playback 3 s @24 fps (emulator): ${seen.size} frames shown of ~72, quality ${h.session.governor.level}")
        }
    }

    @Test
    fun autoQualityStepsDownWhenStillsPlaybackDropsFrames() {
        opened("and10_auto", PreviewQualityMsg.AUTO).use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            h.play()
            h.waitUntil("degraded", 10_000) { h.previewEvents(PreviewEventKindMsg.DEGRADED).isNotEmpty() }
            h.waitUntil("half-size frames") { h.producer.last()?.width == 320 }
            h.waitUntil("frameSize event") { h.previewEvents(PreviewEventKindMsg.FRAME_SIZE).any { it.width == 320L } }
            val ratio = h.sync { h.session.governor.windowDropRatio }
            val degraded = h.previewEvents(PreviewEventKindMsg.DEGRADED)
            assertEquals(PreviewQualityMsg.HALF, degraded.first().quality)
            assertTrue("no recovery while degraded", h.previewEvents(PreviewEventKindMsg.RECOVERED).isEmpty())
            // QA-05 D11: the pause returns auto to full and the paused frame is drawn at full size.
            h.pause()
            h.waitUntil("full-size paused frame") { h.producer.last()?.width == 640 }
            assertEquals(640 to 360, h.sync { h.session.renderSize })
            assertEquals(PreviewQualityMsg.FULL, h.previewEvents(PreviewEventKindMsg.DEGRADED).last().quality)
            assertEquals(1, h.previewEvents(PreviewEventKindMsg.RECOVERED).size)
            val k = h.sync { h.session.playhead }
            assertEquals((PreviewPlans.SOURCE_OFFSET + k).toInt(), barcode(requireNotNull(h.producer.last())))
            Log.i(AND10_TAG, "auto quality under StillFramesBackend load (emulator): ${degraded.map { it.quality }}, drop ratio ${"%.2f".format(ratio)}")
        }
    }

    /** Reports [n] shown and [n] dropped playback frames at [k]: > 10% dropped, one step down. */
    private fun overload(h: PreviewHarness, k: Long, n: Int = 8) = h.sync {
        repeat(n) {
            h.session.frameDisplayed(k)
            h.session.frameDropped(k)
        }
    }

    @Test
    fun aStopReturnsAutoToTheRequestedQualityOnceAndRedrawsThePausedFrame() {
        val b = RecordingBackend()
        PreviewHarness("and10_d11", backend = { b }).apply { open(PreviewQualityMsg.AUTO) }.use { h ->
            fun events(kind: PreviewEventKindMsg) = h.previewEvents(kind)
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            // Pause while not degraded: no quality event.
            h.play()
            b.show(3)
            h.pause()
            Thread.sleep(200)
            assertTrue(events(PreviewEventKindMsg.DEGRADED).isEmpty())
            assertTrue(events(PreviewEventKindMsg.RECOVERED).isEmpty())

            // Degrade during playback, then pause.
            h.play()
            b.show(8)
            overload(h, 8)
            h.waitUntil("half size while playing") { h.sync { h.session.renderSize } == 320 to 180 }
            assertEquals(listOf(PreviewQualityMsg.HALF), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            val n = h.producer.frameCount
            h.pause()
            val f = h.producer.awaitFrame(n)
            assertEquals("the paused frame is drawn again at the requested size", 640, f.width)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 8).toInt(), barcode(f))
            assertEquals(640 to 360, h.sync { h.session.renderSize })
            assertEquals(listOf(PreviewQualityMsg.HALF, PreviewQualityMsg.FULL), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            assertEquals(1, events(PreviewEventKindMsg.RECOVERED).size)
            h.waitUntil("frameSize back at full") { events(PreviewEventKindMsg.FRAME_SIZE).lastOrNull()?.width == 640L }

            // Play again: it starts at the requested level.
            h.play()
            assertEquals(QualityLevel.FULL, h.sync { h.session.governor.level })
            assertEquals(640 to 360, h.sync { h.session.renderSize })
            // pause/play/pause without new drops: no more quality events.
            h.pause()
            h.play()
            b.show(12)
            h.pause()
            Thread.sleep(300)
            assertEquals(2, events(PreviewEventKindMsg.DEGRADED).size)
            assertEquals(1, events(PreviewEventKindMsg.RECOVERED).size)
            // A paused seek renders at the requested size.
            val ack = h.seek(PreviewPlans.grid.timeOfFrame(30))
            assertEquals(30L, ack.displayedFrame)
            assertEquals(640 to 360, h.sync { h.session.renderSize })
        }
    }

    @Test
    fun bTheEndOfThePlanAfterDegradingReturnsAutoToFullAtTheLastFrame() {
        val b = RecordingBackend()
        PreviewHarness("and10_d11_end", backend = { b }).apply { open(PreviewQualityMsg.AUTO) }.use { h ->
            fun events(kind: PreviewEventKindMsg) = h.previewEvents(kind)
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val playSeq = h.play()
            b.show(80)
            overload(h, 80)
            h.waitUntil("half size while playing") { h.sync { h.session.renderSize } == 320 to 180 }
            assertEquals(listOf(PreviewQualityMsg.HALF), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            assertTrue(events(PreviewEventKindMsg.RECOVERED).isEmpty())
            // The backend reaches the end of the plan without a loop.
            val last = PreviewPlans.FRAMES - 1
            val n = h.producer.frameCount
            h.onPreview { b.show(last) }
            h.onPreview { h.session.ended(last) }
            h.waitUntil("ended") { h.clocks().any { !it.playing && it.seq == playSeq } }
            val f = h.producer.awaitFrame(n)
            assertEquals("the last frame is drawn again at full size", 640, f.width)
            assertEquals((PreviewPlans.SOURCE_OFFSET + last).toInt(), barcode(f))
            assertEquals(640 to 360, h.sync { h.session.renderSize })
            assertEquals(QualityLevel.FULL, h.sync { h.session.governor.level })
            assertEquals(last, h.sync { h.session.playhead })
            assertEquals(listOf(PreviewQualityMsg.HALF, PreviewQualityMsg.FULL), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            assertEquals(1, events(PreviewEventKindMsg.RECOVERED).size)
            h.waitUntil("frameSize back at full") { events(PreviewEventKindMsg.FRAME_SIZE).lastOrNull()?.width == 640L }
            // A pause after the end finds nothing to reset: no more events.
            h.pause()
            Thread.sleep(300)
            assertEquals(2, events(PreviewEventKindMsg.DEGRADED).size)
            assertEquals(1, events(PreviewEventKindMsg.RECOVERED).size)
        }
    }

    @Test
    fun cAThermallyCappedStopResetsAutoToHalfWithoutRecovery() {
        val b = RecordingBackend()
        PreviewHarness("and10_d11_thermal", backend = { b }).apply { open(PreviewQualityMsg.AUTO) }.use { h ->
            fun events(kind: PreviewEventKindMsg) = h.previewEvents(kind)
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            // Thermal SEVERE: play polls it and caps the level at half.
            h.sync { h.session.thermalStatusOverride = QualityGovernor.THERMAL_STATUS_SEVERE }
            h.play()
            h.waitUntil("thermal half") { h.sync { h.session.renderSize } == 320 to 180 }
            assertTrue(h.sync { h.session.governor.thermalCapped })
            assertEquals(listOf(PreviewQualityMsg.HALF), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            // Degrade during playback: auto full → half (hidden by the cap), then → quarter, which
            // shows. Steps are at least one window (2 s) apart from the thermal change.
            Thread.sleep(2_100)
            b.show(8)
            overload(h, 8)
            overload(h, 8)
            h.waitUntil("quarter size while playing") { h.sync { h.session.renderSize } == 160 to 90 }
            assertEquals(listOf(PreviewQualityMsg.HALF, PreviewQualityMsg.QUARTER), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            // Pause: auto resets, but only to half while capped; no recovery.
            val n = h.producer.frameCount
            h.pause()
            val f = h.producer.awaitFrame(n)
            assertEquals("the paused frame is drawn again at half size", 320, f.width)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 8).toInt(), barcode(f))
            assertEquals(320 to 180, h.sync { h.session.renderSize })
            assertEquals(QualityLevel.HALF, h.sync { h.session.governor.level })
            assertEquals(listOf(PreviewQualityMsg.HALF, PreviewQualityMsg.QUARTER, PreviewQualityMsg.HALF), events(PreviewEventKindMsg.DEGRADED).map { it.quality })
            h.waitUntil("frameSize at half") { events(PreviewEventKindMsg.FRAME_SIZE).lastOrNull()?.width == 320L }
            Thread.sleep(300)
            assertTrue("no recovery while thermally capped", events(PreviewEventKindMsg.RECOVERED).isEmpty())
        }
    }

    @Test
    fun qualityChangesResizeTheTexture() {
        opened("and10_quality").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val n = h.producer.frameCount
            h.call<Unit> { s, cb -> s.setQuality(PreviewQualityMsg.HALF, cb) }
            val half = h.producer.awaitFrame(n)
            assertEquals(320, half.width)
            assertEquals(180, half.height)
            assertEquals(320 to 180, h.sync { h.session.renderSize })
            h.waitUntil("frameSize event") { h.previewEvents(PreviewEventKindMsg.FRAME_SIZE).any { it.width == 320L } }
            assertTrue("a requested quality is not a degradation", h.previewEvents(PreviewEventKindMsg.DEGRADED).isEmpty())
            h.call<Unit> { s, cb -> s.setQuality(PreviewQualityMsg.AUTO, cb) }
            h.waitUntil("full-size frame") { h.producer.last()?.width == 640 }
            assertEquals(640 to 360, h.sync { h.session.renderSize })
        }
    }

    @Test
    fun exportSuspensionPausesAndDefersWork() {
        opened("and10_suspend").use { h ->
            h.manager.suspendTiers = DeviceTierMsg.entries.toSet()
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), PreviewPlans.box()), rev = 1))
            h.producer.awaitFrame(0)
            h.play()
            h.manager.suspendForExport("job1")
            h.waitUntil("suspended") { h.sync { h.session.isSuspended && !h.session.playing } }
            Thread.sleep(300) // a playback still already being composed may still land
            val busy = runCatching { h.play() }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.busy, busy.code)
            assertTrue(busy.retryable)
            assertEquals(EngineErrorCode.busy, (runCatching { h.seek(0) }.exceptionOrNull() as EngineException).code)
            val n = h.producer.frameCount
            assertEquals(2L, h.patch(PreviewPlans.upsert(1, PreviewPlans.box(cx = 400.0))).rev)
            Thread.sleep(300)
            assertEquals("no render while suspended", n, h.producer.frameCount)
            h.manager.resumeAfterExport("job1")
            h.producer.awaitFrame(n)
            h.waitUntil("resumed") { h.sync { !h.session.isSuspended } }
            assertEquals("busy commands take no seq", 2L, h.play())
        }
    }

    @Test
    fun lookStillsColourSamplesAndSourceFrames() {
        opened("and10_stills").use { h ->
            val image = PlanLayer(
                id = "img#v", z = 40, t0 = 0, t1 = PreviewPlans.grid.timeOfFrame(PreviewPlans.FRAMES), kind = PlanLayerKind.IMAGE, asset = "alpha",
                base = PlanSize(120.0, 120.0), xf = PlanTransform(cx = 560.0, cy = 280.0),
            )
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), image), rev = 1))
            h.producer.awaitFrame(0)
            val looks = listOf(
                LookSpecMsg("none", "", 0, 1.0),
                LookSpecMsg("warm", "file:///and17/look.vlut", 33, 1.0),
            )
            val stills = h.call<List<ByteArray>> { s, cb -> s.renderLookStills("main", looks, 90, cb) }
            assertEquals(2, stills.size)
            val bitmaps = stills.map { assertNotNull(BitmapFactory.decodeByteArray(it, 0, it.size)); BitmapFactory.decodeByteArray(it, 0, it.size) }
            assertEquals(90, bitmaps[0].height)
            assertEquals(160, bitmaps[0].width)
            val a = IntArray(160 * 90).also { bitmaps[0].getPixels(it, 0, 160, 0, 0, 160, 90) }
            val b = IntArray(160 * 90).also { bitmaps[1].getPixels(it, 0, 160, 0, 0, 160, 90) }
            assertTrue("the LUT look differs from none", a.indices.count { a[it] != b[it] } > a.size / 4)
            val color = h.call<com.vecvel.danaview.editor.engine.pigeon.ColorMsg?> { s, cb -> s.sampleColor("main", 0.5, 0.3, cb) }
            assertNotNull(color)
            assertEquals(1.0, color!!.alpha, 1e-9)
            val img = h.call<com.vecvel.danaview.editor.engine.pigeon.ColorMsg?> { s, cb -> s.sampleColor("img", 0.5, 0.5, cb) }
            assertNotNull(img)
            assertNull(h.call<com.vecvel.danaview.editor.engine.pigeon.ColorMsg?> { s, cb -> s.sampleColor("nope", 0.5, 0.5, cb) })
            val e = runCatching { h.call<List<ByteArray>> { s, cb -> s.renderLookStills("img", looks, 90, cb) } }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)

            // Trim-edge source frame: shown instead of the timeline, cleared by the next seek.
            val uri = PausedPlans.assets().getValue("counter").uri
            val n = h.producer.frameCount
            h.call<Unit> { s, cb -> s.showSourceFrame(ResolvedMediaMsg(uri, "fp-counter24", null, false), PreviewPlans.grid.timeOfFrame(150), cb) }
            val src = h.producer.awaitFrame(n)
            assertEquals(150, barcode(src))
            assertEquals(37L, h.seek(PreviewPlans.grid.timeOfFrame(37)).displayedFrame)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 37).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
        }
    }

    @Test
    fun disposeReleasesTheTextureAndIsIdempotent() {
        val h = opened("and10_dispose")
        try {
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            val id = h.opened.sessionId
            await<Unit> { cb -> h.onPreview { h.session.dispose(cb) } }
            assertTrue(h.producer.released)
            assertNull(h.manager.get(id))
            await<Unit> { cb -> h.onPreview { h.session.dispose(cb) } }
            val e = runCatching { h.play() }.exceptionOrNull() as EngineException
            assertEquals(EngineErrorCode.cancelled, e.code)
            // A second session on the same registry, then releaseAll for that registry.
            val other = await<com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg> { cb ->
                h.onPreview { h.manager.open(com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg(640, 360, 24, PreviewQualityMsg.AUTO, false), h.textures, cb) }
            }
            assertNotNull(h.manager.get(other.sessionId))
            h.onPreview { h.manager.releaseAll(h.textures) }
            h.waitUntil("released") { h.manager.get(other.sessionId) == null }
            assertTrue(h.textures.producers.last().released)
        } finally {
            try {
                h.engine.close()
            } catch (t: Throwable) {
                fail("close: $t")
            }
        }
    }

    private object TextureRegistryLifecycle {
        const val RESET_IN_BACKGROUND = "resetInBackground"
    }
}
