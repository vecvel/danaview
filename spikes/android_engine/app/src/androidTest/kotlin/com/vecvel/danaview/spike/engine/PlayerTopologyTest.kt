@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * R1 go/no-go evidence: which composition topologies Media3 1.11.1 `CompositionPlayer` plays.
 * Every test asserts the behaviour observed on the API 35 emulator, so a Media3 upgrade that
 * changes it fails here and AND-01's verdict must be revisited.
 *
 * Findings (AND-01.md "R1"): any item→item, gap→item or item→gap transition inside a
 * *secondary* sequence stalls video at the boundary while the clock keeps running; an image item
 * as sequence 0 (the ARCH clock band) never lets the player reach STATE_ENDED; the same
 * transitions in the *primary* sequence play; no exact seek renders with MultipleInputVideoGraph.
 */
@RunWith(AndroidJUnit4::class)
class PlayerTopologyTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)

    /** [maxK] = last output frame composited (probe), not the last one released to the surface. */
    private data class Outcome(val ended: Boolean, val maxK: Long, val json: JSONObject)

    private fun play(
        name: String,
        plan: SpikePlan,
        options: MapperOptions,
        perStream: Boolean = false,
        dropLateInput: Boolean = false,
        waitMs: Long = 15_000,
    ): Outcome {
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        // Composition-level probe without regions: records every composited output frame, so a
        // late frame dropped at release (slow emulator host) is not mistaken for a stall.
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), emptyList())
        val c = mapper.build(plan, store, options.copy(probe = probe))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH, dropLateInput = dropLateInput, configure = { it.setPerStreamMediaProgressionEnabled(perStream) }).use { h ->
            h.load(c)
            h.awaitReady()
            probe.clear()
            val t0 = System.nanoTime()
            val ended = h.playToEnd(plan.durUs / 1000 + waitMs)
            val maxRendered = GridTime.frameIndexNearest(h.rendered.maxOfOrNull { it.ptsUs } ?: -1, plan.fps)
            val maxComposed = GridTime.frameIndexNearest(probe.frames.maxOfOrNull { it.ptsUs } ?: -1, plan.fps)
            val json = JSONObject().put("variant", name).put("ended", ended)
                .put("wallMs", (System.nanoTime() - t0) / 1e6)
                .put("expectedFrames", plan.durFrames)
                .put("dropLateInput", dropLateInput)
                .put("composedFrames", probe.frames.map { GridTime.frameIndexNearest(it.ptsUs, plan.fps) }.toSet().size)
                .put("maxComposedK", maxComposed)
                .put("renderedFrames", h.rendered.size).put("maxRenderedK", maxRendered)
                .put("positionMsAfterWait", h.positionMs())
            Results.write("R1_$name", json)
            return Outcome(ended, maxComposed, json)
        }
    }

    private fun layer(id: String, seq: Int, k0: Long, k1: Long, srcSec: Double) =
        SpikeLayer(id, seq, k0, k1, TestMedia.uri("barcode_30.mp4"), Scenarios.srcAt("barcode_30.mp4", srcSec), Scenarios.RECTS.getValue(seq))

    private fun plan(layers: List<SpikeLayer>) = SpikePlan(Scenarios.W, Scenarios.H, 30, 30, 60, layers)

    private val bare = MapperOptions(includeAudio = false, includeBackground = false)
    private val videoClock get() = Scenarios.videoClock(30, bare)
    private val twoItems get() = plan(listOf(layer("A", 1, 0, 31, 0.8), layer("B", 1, 31, 60, 6.5)))

    @Test
    fun imageClockBand_neverReachesEnded() {
        val o = play("image_clock_single", plan(listOf(layer("A", 1, 0, 60, 0.8))), bare)
        assertFalse("image clock band now reaches ENDED: revisit the AND-01 clock-band finding", o.ended)
        assertEquals("every frame is still composited", 59L, o.maxK)
    }

    @Test
    fun videoClockBand_reachesEnded() {
        val o = play("video_clock_single", plan(listOf(layer("A", 1, 0, 60, 0.8))), videoClock)
        assertTrue(o.json.toString(), o.ended)
        assertEquals(59L, o.maxK)
    }

    @Test
    fun secondaryItemTransition_stalls() {
        val o = play("secondary_item_to_item", twoItems, videoClock)
        assertFalse("secondary item transitions now play: R1 may be a go, rerun AND-01", o.ended)
        assertTrue("stalled at the boundary (k=31): ${o.json}", o.maxK in 20L..33L)
    }

    @Test
    fun secondaryItemTransition_perStreamProgression_stalls() {
        val o = play("secondary_item_to_item_per_stream", twoItems, videoClock, perStream = true)
        assertFalse(o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..33L)
    }

    @Test
    fun secondaryItemTransition_imageClock_stalls() {
        val o = play("secondary_item_to_item_image_clock", twoItems, bare)
        assertFalse(o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..33L)
    }

    @Test
    fun secondaryGapToItem_stalls() {
        val o = play("secondary_gap_to_item", plan(listOf(layer("D", 1, 34, 60, 4.0))), videoClock)
        assertFalse(o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..36L)
    }

    @Test
    fun secondaryItemToGap_stalls() {
        val o = play("secondary_item_to_gap", plan(listOf(layer("A", 1, 0, 31, 0.8))), videoClock)
        assertFalse(o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..33L)
    }

    @Test
    fun secondaryItemTransition_noItemEffects_stalls() {
        // Without any per-item effect (no PlaceEffect, nothing to re-register at the boundary).
        val o = play("secondary_item_to_item_no_effects", twoItems, videoClock.copy(noItemEffects = true))
        assertFalse(o.json.toString(), o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..33L)
    }

    @Test
    fun secondaryItemTransition_lateBoundary_stallsAtBoundary() {
        // Boundary at k = 61 of 90: the stall tracks the boundary, not a fixed buffer horizon.
        val plan = SpikePlan(Scenarios.W, Scenarios.H, 30, 30, 90, listOf(layer("A", 1, 0, 61, 0.8), layer("B", 1, 61, 90, 6.5)))
        val o = play("secondary_item_to_item_late_boundary", plan, videoClock)
        assertFalse(o.json.toString(), o.ended)
        assertTrue(o.json.toString(), o.maxK in 50L..63L)
    }

    @Test
    fun secondaryItemTransition_defaultDropPolicy_longWait_stalls() {
        // Media3's default late-drop policy and a 45 s wait: a stall, not a slow host.
        val o = play("secondary_item_to_item_default_drop_45s", twoItems, videoClock, dropLateInput = true, waitMs = 45_000)
        assertFalse(o.json.toString(), o.ended)
        assertTrue(o.json.toString(), o.maxK in 20L..33L)
    }

    /**
     * Seeking past a secondary boundary does not get around the stall: with MultipleInputVideoGraph
     * no paused seek renders the requested frame and playback does not resume afterwards
     * (SeekDiagnosticsTest.compositionPlayerSeekIsolation has the minimal reproduction).
     */
    @Test
    fun secondaryItemTransition_seekPastBoundary_fails() {
        val plan = twoItems
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), Scenarios.regions(1))
        val c = mapper.build(plan, store, videoClock.copy(probe = probe))
        var got: Pair<RenderedFrame, Double>? = null
        var ended = false
        var maxK = -1L
        var error: String? = null
        try {
            PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
                h.load(c)
                h.awaitReady()
                val k = 40L
                got = h.seekAndAwait(GridTimingTest.seekMs(k, plan.fps), 10_000) { GridTime.frameIndexNearest(it.ptsUs, plan.fps) == k }
                probe.clear()
                ended = h.playToEnd(plan.durUs / 1000 + 10_000)
                maxK = GridTime.frameIndexNearest(probe.frames.maxOfOrNull { it.ptsUs } ?: -1, plan.fps)
            }
        } catch (t: Throwable) {
            error = generateSequence(t) { it.cause }.take(4).joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }
        }
        val json = JSONObject().put("variant", "secondary_seek_past_boundary").put("seekAcked", got != null)
            .put("seekLatencyMs", got?.second ?: -1.0).put("endedAfterPlayFromSeek", ended).put("maxComposedK", maxK)
            .put("error", error ?: JSONObject.NULL)
        Results.write("R1_secondary_seek_past_boundary", json)
        assertFalse("seek past a secondary boundary now works: R1 may be a go, rerun AND-01: $json", got != null && ended)
    }

    /**
     * Exact seeks with the ARCH image clock band vs the video clock band on a single-item
     * composition: with MultipleInputVideoGraph neither acks a single seek (R1).
     */
    @Test
    fun clockBandKinds_exactSeeks() {
        val plan = plan(listOf(layer("A", 1, 0, 60, 0.8)))
        val out = JSONObject()
        for ((name, options) in listOf("image" to bare, "video" to videoClock)) {
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            var acked = 0
            var error: String? = null
            try {
                PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
                    h.load(mapper.build(plan, store, options))
                    h.awaitReady()
                    for (k in listOf(45L, 7L, 52L, 1L, 30L)) {
                        if (h.seekAndAwait(GridTimingTest.seekMs(k, plan.fps), 3_000) { GridTime.frameIndexNearest(it.ptsUs, plan.fps) == k } != null) acked++
                    }
                }
            } catch (t: Throwable) {
                error = generateSequence(t) { it.cause }.take(4).joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }
            }
            out.put(name, JSONObject().put("seeks", 5).put("acked", acked).put("error", error ?: JSONObject.NULL))
        }
        Results.write("R1_clock_band_seeks", out)
        for (name in listOf("image", "video")) {
            assertEquals("multi-sequence seeks now ack ($name): R1 may be a go, rerun AND-01: $out", 0, out.getJSONObject(name).getInt("acked"))
        }
    }

    @Test
    fun primaryItemTransition_plays() {
        // No clock band: the two-item sequence is the primary; the background image is secondary.
        val o = play("primary_item_to_item", twoItems, MapperOptions(includeClockBand = false, includeAudio = false))
        assertTrue(o.json.toString(), o.ended)
        assertEquals(59L, o.maxK)
    }
}
