@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.Player
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.spike.engine.Scenarios.json
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N1 (getOverlaySettings input id = sequence index, pts = composition time), V-N2 (effect pts
 * are sequence-cumulative in CompositionPlayer and Transformer) and V-N4 (straight alpha) on the
 * canonical AND-01 composition (clock band, 3 video sequences with gaps, background, 2 audio-only).
 */
@RunWith(AndroidJUnit4::class)
class CompositorContractTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)

    private class Run(val probe: ProbeEffect, val effects: EffectRecorder, val overlays: ConcurrentLinkedQueue<OverlayCall>)

    private fun contractJson(plan: SpikePlan, run: Run): JSONObject {
        val n = plan.visualSequenceCount
        val ids = run.overlays.map { it.inputId }.toSortedSet()
        // pts handed to getOverlaySettings for secondary inputs: on P(k) (composition time) or offset?
        val overlayOffsets = run.overlays.filter { it.inputId in 1..n }.map {
            it.ptsUs - GridTime.platformTimeOfFrame(GridTime.frameIndexNearest(it.ptsUs, plan.fps), plan.fps)
        }
        val effectOffsets = (1..n).associateWith { seq ->
            run.effects.of(seq).map { it.ptsUs - GridTime.platformTimeOfFrame(GridTime.frameIndexNearest(it.ptsUs, plan.fps), plan.fps) }
        }
        val effectRanges = (1..n).associateWith { seq ->
            val calls = run.effects.of(seq)
            JSONObject().put("calls", calls.size)
                .put("minPts", calls.minOfOrNull { it.ptsUs })
                .put("maxPts", calls.maxOfOrNull { it.ptsUs })
                .put("activeCalls", calls.count { it.active })
                .put("ptsMinusPkHistogram", JSONObject(effectOffsets.getValue(seq).groupingBy { it }.eachCount().mapKeys { it.key.toString() }))
        }
        return JSONObject()
            .put("overlayInputIds", Results.arr(ids))
            .put("overlayCalls", run.overlays.size)
            .put("overlayPtsMinusPkHistogram", JSONObject(overlayOffsets.groupingBy { it }.eachCount().mapKeys { it.key.toString() }))
            .put("effects", JSONObject(effectRanges.mapKeys { "seq${it.key}" }))
    }

    private fun newRun(plan: SpikePlan): Run {
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1, 2, 3))
        return Run(probe, EffectRecorder(), ConcurrentLinkedQueue())
    }

    @Test
    fun canonicalComposition_export_vn1_vn2() {
        val plan = Scenarios.gridCut(30)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val run = newRun(plan)
        val c = mapper.build(plan, store, MapperOptions(probe = run.probe, recorder = run.effects, overlayRecorder = run.overlays))
        val out = ExportHarness(ctx).export(c, File(TestMedia.outDir, "contract_export.mp4"))
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val check = Scenarios.check(plan, run.probe.frames.toList(), times, listOf(1, 2, 3))
        val json = contractJson(plan, run)
            .put("target", "transformer")
            .put("exportFrames", out.result.videoFrameCount)
            .put("exportWallMs", out.wallMs)
            .put("barcode", check.json())
        Results.write("VN01_VN02_export", json)
        assertEquals(plan.durFrames.toInt(), out.result.videoFrameCount)
        assertEquals((0..plan.visualSequenceCount + 1).toSortedSet(), run.overlays.map { it.inputId }.toSortedSet())
        assertTrue(check.mismatches.joinToString("\n"), check.mismatches.isEmpty())
        // Effect pts are composition times: the latest seq-1 pts reaches the last frame of item C.
        val maxSeq1 = run.effects.of(1).maxOf { it.ptsUs }
        assertTrue("seq1 max pts $maxSeq1", maxSeq1 >= GridTime.platformTimeOfFrame(plan.durFrames - 1, plan.fps))
    }

    /**
     * V-N1 in CompositionPlayer on the canonical composition (video clock band so the player runs;
     * see PlayerTopologyTest): overlay input ids and pts for the frames composed before the first
     * secondary-sequence transition stalls playback.
     */
    @Test
    fun canonicalComposition_player_vn1() {
        val plan = Scenarios.gridCut(30)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val run = newRun(plan)
        val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(probe = run.probe, recorder = run.effects, overlayRecorder = run.overlays)))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.load(c)
            h.awaitReady()
            run.probe.clear(); run.effects.clear(); run.overlays.clear()
            val ended = h.playToEnd(plan.durUs / 1000 + 15_000)
            val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
            val check = Scenarios.check(plan, run.probe.frames.toList(), times, listOf(1, 2, 3))
            val json = contractJson(plan, run)
                .put("target", "compositionPlayer")
                .put("ended", ended)
                .put("maxComposedK", GridTime.frameIndexNearest(run.probe.frames.maxOfOrNull { it.ptsUs } ?: -1, plan.fps))
                .put("renderedFrames", h.rendered.size)
                .put("droppedFrames", h.dropped.get())
                .put("barcode", check.json())
            Results.write("VN01_player", json)
            assertTrue(check.mismatches.joinToString("\n"), check.mismatches.isEmpty())
            assertEquals((0..plan.visualSequenceCount + 1).toSortedSet(), run.overlays.map { it.inputId }.toSortedSet())
            // Secondary overlay pts are composition times of the secondary frame (P(k) + clip shift).
            assertTrue(run.overlays.filter { it.inputId in 1..3 }.all { Math.abs(it.ptsUs - GridTime.platformTimeOfFrame(GridTime.frameIndexNearest(it.ptsUs, 30), 30)) <= 1000 })
        }
    }

    /**
     * V-N2 in CompositionPlayer: effect pts after an item transition. Item transitions only play in
     * the primary sequence, so the two-item sequence is the primary here (no clock band).
     */
    @Test
    fun primarySequence_player_vn2() {
        val src = "barcode_30.mp4"
        val a = SpikeLayer("A", 1, 0, 31, TestMedia.uri(src), Scenarios.srcAt(src, 0.8), Scenarios.RECTS.getValue(1))
        val b = SpikeLayer("B", 1, 31, 60, TestMedia.uri(src), Scenarios.srcAt(src, 6.5), Scenarios.RECTS.getValue(1))
        val plan = SpikePlan(Scenarios.W, Scenarios.H, 30, 30, 60, listOf(a, b))
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val rec = EffectRecorder()
        val c = mapper.build(plan, store, MapperOptions(recorder = rec, includeClockBand = false, includeAudio = false))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.load(c)
            h.awaitReady()
            rec.clear()
            val ended = h.playToEnd(plan.durUs / 1000 + 30_000)
            val bCalls = rec.of(1).filter { it.ptsUs >= GridTime.platformTimeOfFrame(31, 30) - 1000 }
            val json = JSONObject().put("ended", ended).put("calls", rec.of(1).size)
                .put("minPts", rec.of(1).minOfOrNull { it.ptsUs }).put("maxPts", rec.of(1).maxOfOrNull { it.ptsUs })
                .put("callsAtOrAfterItemB", bCalls.size)
            Results.write("VN02_player_primary", json)
            assertTrue(json.toString(), ended)
            assertTrue("effect pts are composition-cumulative across items: $json", bCalls.size >= 25)
        }
    }

    // ------------------------------------------------------------------ V-N4

    private fun alphaPlan(): SpikePlan {
        val src = TestMedia.uri("barcode_30.mp4")
        val d = 30L
        val left = floatArrayOf(0f, 0f, 640f, 720f)
        val bottom = floatArrayOf(0f, 360f, 1280f, 360f)
        return SpikePlan(
            Scenarios.W, Scenarios.H, 30, 30, d,
            listOf(
                SpikeLayer("red", 1, 0, d, src, 0, left, alpha = 0.5f, solid = floatArrayOf(1f, 0f, 0f, 0.5f)),
                SpikeLayer("green", 2, 0, d, src, 0, bottom, alpha = 0.5f, solid = floatArrayOf(0f, 1f, 0f, 0.5f)),
            ),
        )
    }

    private val alphaRegions = listOf(
        ProbeRegion("topLeft", floatArrayOf(0f, 0f, 640f, 360f)),
        ProbeRegion("topRight", floatArrayOf(640f, 0f, 640f, 360f)),
        ProbeRegion("bottomLeft", floatArrayOf(0f, 360f, 640f, 360f)),
        ProbeRegion("bottomRight", floatArrayOf(640f, 360f, 640f, 360f)),
    )

    /** Straight-alpha "over" of red(0.5) and green(0.5) on the 0x336699 background. */
    private val alphaExpected = mapOf(
        "topLeft" to floatArrayOf(0.6f, 0.2f, 0.3f),
        "topRight" to floatArrayOf(0.2f, 0.4f, 0.6f),
        "bottomLeft" to floatArrayOf(0.55f, 0.35f, 0.15f),
        "bottomRight" to floatArrayOf(0.1f, 0.7f, 0.3f),
    )

    private fun alphaJson(frames: List<Map<String, RegionReading>>): Pair<JSONObject, Int> {
        var bad = 0
        val out = JSONObject()
        for ((name, want) in alphaExpected) {
            val px = frames.map { it.getValue(name).grey }
            val worst = px.maxOf { p -> maxOf(Math.abs(Barcode.r(p) - want[0]), Math.abs(Barcode.g(p) - want[1]), Math.abs(Barcode.b(p) - want[2])) }
            if (worst > 0.03f) bad++
            val p = px.first()
            out.put(name, JSONObject().put("want", JSONArray(want.toList())).put("got", JSONArray(listOf(Barcode.r(p), Barcode.g(p), Barcode.b(p)))).put("worstErr", worst.toDouble()))
        }
        return out to bad
    }

    @Test
    fun straightAlpha_export_vn4() {
        val plan = alphaPlan()
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), alphaRegions)
        val c = mapper.build(plan, store, MapperOptions(probe = probe, includeAudio = false))
        ExportHarness(ctx).export(c, File(TestMedia.outDir, "alpha_export.mp4"))
        val (json, bad) = alphaJson(probe.frames.map { it.regions })
        Results.write("VN04_alpha_export", json.put("frames", probe.frames.size))
        assertEquals(json.toString(), 0, bad)
    }

    @Test
    fun straightAlpha_player_vn4() {
        val plan = alphaPlan()
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(includeAudio = false)))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.readRows = Scenarios.rowsFor(alphaRegions)
            h.load(c)
            h.awaitReady()
            val t0 = System.nanoTime()
            // Played to frame 10 and paused (multi-sequence seeks fail in Media3 1.11.1, R1).
            val got = h.playUntilFrame(10, 30, 15_000) ?: error("no frame")
            val img = h.imageOf(got, t0) ?: error("no image")
            val (json, bad) = alphaJson(listOf(Scenarios.readImage(img, alphaRegions, plan.bgRgb())))
            Results.write("VN04_alpha_player", json)
            assertEquals(json.toString(), 0, bad)
        }
    }

    // ------------------------------------------------------------------ export vs player frames

    @Test
    fun exportMatchesPlayer_ssim() {
        val plan = Scenarios.fullLength(30, 3)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val ks = setOf(10L, 45L, 80L, 110L)
        val playerProbe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.gridRegions(3)).apply {
            captureFull = { pts -> GridTime.frameIndexNearest(pts, 30) in ks }
        }
        val options = Scenarios.videoClock(30, MapperOptions(includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.load(mapper.build(plan, store, options.copy(probe = playerProbe)))
            h.awaitReady()
            playerProbe.clear()
            h.playToEnd(plan.durUs / 1000 + 60_000)
        }
        val out = ExportHarness(ctx).export(mapper.build(plan, store, options), File(TestMedia.outDir, "ssim_export.mp4"))
        val decodedProbe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.gridRegions(3)).apply {
            captureFull = { pts -> GridTime.frameIndexNearest(pts, 30) in ks }
        }
        val decoded = ExportHarness(ctx).probeFile(out.file, decodedProbe)
        val results = JSONObject()
        var worst = 1.0
        for (k in ks) {
            val a = playerProbe.frames.lastOrNull { GridTime.frameIndexNearest(it.ptsUs, 30) == k && it.full != null }?.full
            val b = decoded.lastOrNull { GridTime.frameIndexNearest(it.ptsUs, 30) == k && it.full != null }?.full
            val v = if (a == null || b == null) 0.0 else Ssim.ssim(a, b, plan.canvasW, plan.canvasH)
            results.put("k$k", v)
            worst = minOf(worst, v)
        }
        Results.write("SSIM_export_vs_player", results.put("worst", worst))
        assertTrue("SSIM $results", worst >= 0.98)
    }
}
