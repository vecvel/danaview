@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.spike.engine.Scenarios.json
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N18 grid timing (ARCH §5, D-35): secondary-frame selection and the grid-cut barcode case
 * (cuts at k ≡ 1, 2 mod 3, boundaries anchored at P(k)) in CompositionPlayer playback and
 * Transformer export. Seek semantics, exact seek and scrub: SeekDiagnosticsTest and
 * ContingencyEngineTest.
 */
@RunWith(AndroidJUnit4::class)
class GridTimingTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)
    private val seqs = listOf(1, 2, 3)

    private fun probeFor(plan: SpikePlan) = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1, 2, 3))

    // Seek semantics, exact seek 200/200 and scrubbing: CompositionPlayer with
    // MultipleInputVideoGraph (the only graph that composites several sequences) cannot seek at
    // all in Media3 1.11.1 (SeekDiagnosticsTest, R1), so these V-N18 questions are answered by
    // SeekDiagnosticsTest (ExoPlayer EXACT seek semantics → androidSeekMsRounding = floor) and by
    // ContingencyEngineTest (exact seek 200/200 and scrub on the grid-cut composition).

    /**
     * Grid-cut playback in CompositionPlayer. Media3 1.11.1 stalls at the first item/gap boundary
     * of a secondary sequence (PlayerTopologyTest, AND-01 R1 no-go), so this records how far
     * playback composites and checks every composited frame against the rule; the 100% playback
     * case is carried by the contingency prototype (ContingencyEngineTest).
     */
    private fun playback(fps: Int) {
        val plan = Scenarios.gridCut(fps)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = probeFor(plan)
        val times = TestMedia.videoSampleTimesUs("barcode_$fps.mp4")
        val c = mapper.build(plan, store, Scenarios.videoClock(fps, MapperOptions(probe = probe)))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.load(c)
            h.awaitReady()
            probe.clear()
            val t0 = System.nanoTime()
            val ended = h.playToEnd(plan.durUs / 1000 + 15_000)
            val wallMs = (System.nanoTime() - t0) / 1e6
            val check = Scenarios.check(plan, probe.frames.toList(), times, seqs)
            val rendered = h.rendered.filter { it.wallNs >= t0 }
            val maxK = GridTime.frameIndexNearest(probe.frames.maxOfOrNull { it.ptsUs } ?: -1, fps)
            // First secondary boundary (any layer edge after 0 in sequences 1..3).
            val firstEdge = plan.layers.flatMap { listOf(it.k0, it.k1) }.filter { it in 1 until plan.durFrames }.min()
            Results.write(
                "VN18_playback_$fps",
                JSONObject().put("fps", fps).put("ended", ended).put("wallMs", wallMs)
                    .put("compositionMs", plan.durUs / 1000)
                    .put("renderedFrames", rendered.size).put("expectedFrames", plan.durFrames)
                    .put("maxComposedK", maxK).put("firstSecondaryBoundaryK", firstEdge)
                    .put("droppedFrames", h.dropped.get()).put("barcode", check.json()),
            )
            assertTrue(check.mismatches.joinToString("\n"), check.mismatches.isEmpty())
            assertEquals(0, check.offGrid)
            if (ended) {
                assertEquals("every output frame composited", plan.durFrames.toInt(), check.distinctK)
            } else {
                // The documented stall: composition stops within half a second before the first
                // secondary boundary (a gap→item boundary stalls a few frames early).
                assertTrue("stall at $maxK, first boundary $firstEdge", maxK in firstEdge - fps / 2 until firstEdge)
            }
        }
    }

    /**
     * Grid-cut Transformer export with the ARCH image clock band. [gapFill] GAP is `addGap`;
     * TRANSPARENT_IMAGE fills secondary gaps with transparent image items at the output fps
     * (AND-01 finding: Media3 gap frames are sparser than the 60 fps grid, so its nearest
     * secondary-frame selection shows an item's first frame one output frame early).
     */
    private fun export(
        fps: Int,
        gapFill: GapFill = GapFill.GAP,
        epsilon: EpsilonMode = EpsilonMode.SHIFT_START_500,
        name: String = "VN18_export_$fps",
        strict: Boolean = true,
    ) {
        val plan = Scenarios.gridCut(fps)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = probeFor(plan)
        val times = TestMedia.videoSampleTimesUs("barcode_$fps.mp4")
        val c = mapper.build(plan, store, MapperOptions(probe = probe, gapFill = gapFill, epsilon = epsilon))
        val out = ExportHarness(ctx).export(c, File(TestMedia.outDir, "$name.mp4"))
        val composed = Scenarios.check(plan, probe.frames.toList(), times, seqs)
        // The encoded file decoded again through the same probe (catches encoder/muxer timing).
        val decodedProbe = probeFor(plan)
        val decoded = ExportHarness(ctx).probeFile(out.file, decodedProbe)
        val decodedCheck = Scenarios.check(plan, decoded, times, seqs)
        Results.write(
            name,
            JSONObject().put("fps", fps).put("gapFill", gapFill.name).put("epsilon", epsilon.name)
                .put("exportFrames", out.result.videoFrameCount).put("wallMs", out.wallMs)
                .put("composed", composed.json()).put("decodedOutput", decodedCheck.json()),
        )
        assertEquals(plan.durFrames.toInt(), out.result.videoFrameCount)
        if (!strict) {
            // Recorded comparison (addGap at 60 fps): at most the documented one-frame-early item
            // start after a gap, never content in a gap.
            assertTrue(composed.mismatches.joinToString("\n"), composed.mismatches.size <= 3)
            return
        }
        assertTrue(composed.mismatches.joinToString("\n"), composed.mismatches.isEmpty())
        assertTrue(decodedCheck.mismatches.joinToString("\n"), decodedCheck.mismatches.isEmpty())
        assertEquals(plan.durFrames.toInt(), decodedCheck.distinctK)
    }

    @Test fun playbackBarcode24_vn18() = playback(24)
    @Test fun playbackBarcode30_vn18() = playback(30)
    @Test fun playbackBarcode60_vn18() = playback(60)
    @Test fun exportBarcode24_vn18() = export(24)
    @Test fun exportBarcode30_vn18() = export(30)
    /** addGap at 60 fps shows one item's first frame one output frame early (recorded, AND-01.md). */
    @Test fun exportBarcode60_vn18() = export(60, strict = false)

    /** The mechanisms AND-08/AND-11 adopt: transparent-image gap fill + rule-frame clip starts. */
    @Test fun exportBarcode24_gapFill_vn18() = export(24, GapFill.TRANSPARENT_IMAGE, EpsilonMode.SNAP_TO_RULE_FRAME, "VN18_export_gapfill_24")
    @Test fun exportBarcode30_gapFill_vn18() = export(30, GapFill.TRANSPARENT_IMAGE, EpsilonMode.SNAP_TO_RULE_FRAME, "VN18_export_gapfill_30")
    @Test fun exportBarcode60_gapFill_vn18() = export(60, GapFill.TRANSPARENT_IMAGE, EpsilonMode.SNAP_TO_RULE_FRAME, "VN18_export_gapfill_60")

    companion object {
        /**
         * Measured by SeekDiagnosticsTest.exoPlayerExactSeekSemantics (ExoPlayer EXACT seeks show the
         * first frame at or after the position); becomes frame_grid.json's `androidSeekMsRounding` (ENG-06).
         */
        const val SEEK_ROUNDING = "floor"

        fun seekMs(k: Long, fps: Int): Long =
            if (SEEK_ROUNDING == "ceil") GridTime.platformMsCeil(k, fps) else GridTime.platformMsFloor(k, fps)
    }
}
