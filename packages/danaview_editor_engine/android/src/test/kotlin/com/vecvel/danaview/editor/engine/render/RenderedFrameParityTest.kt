// OWNER: AND-18
//
// Which source frame a rendered range shows for a layer, against the live rule (ARCH §11.5, D-35),
// on the JVM. The render path is the production one up to Media3: RenderPreviewSpecs.exportPlan →
// CompositionMapper (rule-frame clip start, P(k)-anchored items, transparent gap images at the
// output fps). Media3's DefaultVideoCompositor is modelled by its documented secondary-frame
// choice (AND-01 V-N18): the secondary frame NEAREST the primary (clock band) pts P(k), a tie
// taking the earlier frame. A frame j of a 1× item reaches the compositor at
// `startUs + (pts(j) − clipStartUs)`. The live path shows RuleFrameMath.rule(pts, s) with
// s = PausedFrames.sourceTimeUs(layer, timeOfFrame(k)).
//
// Findings these tests pin (android-r8, the "one layer one frame behind" render-file defect):
// - Same source and project rate (24/30/60), in-points on and off the source frame grid, layer
//   starts at k ≡ 0, 1, 2 (mod 3): the render shows exactly the live rule frame at every output
//   frame. The timing a range render feeds Media3 cannot produce a wrong frame.
// - The one window where they can differ is an in-point within ±2 µs of `pts(J) − ε` or
//   `pts(J+1) − ε` (ε = 500 µs): the live rule then flips with the ±1 µs jitter of
//   ceil(k·1e6/fps) while the compositor's nearest choice does not. Not exercised here (and not
//   the failing fixtures, whose in-points are floor(J·1e6/fps), 1 µs below pts(J) at most).
// - A source frame LOST before the compositor shows the NEXT frame (+1) with the counters' PTS
//   tables (timescale 600: pts = floor(j·1e6/fps)), for the two wrong frames Windows saw
//   (e2c6b71b: k=57 s0 want 221 got 220, k=40 s1 want 126 got 125). So a -1 with the file frame at
//   P(k) is the right frame slot carrying the previous frame's pixels (stale content inside
//   Media3's decoder → texture → compositor chain), not a timing or frame-loss effect.
// - Different source and project rates follow Media3's nearest choice, not the floor rule
//   (AND-01 V-N15): 24 → 30 shows the next source frame (+1) on some output frames; 60 → 30 is
//   exact. Never −1.
// - A layer running past its source end (android-r9; K4/K5 of the six-layer chroma-key range want
//   counter frames 130–249 and 160–279 of 240): live holds the last frame (the rule frame of any s
//   past it). The render now plays the source at 1× up to the first output frame whose rule frame
//   is the last one and holds that frame (a still at the output fps) to the layer's end, instead
//   of SpeedFit slowing the remaining source over the whole layer. Render = live at every frame.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.ItemKind
import com.vecvel.danaview.editor.engine.composition.ItemSpec
import com.vecvel.danaview.editor.engine.composition.SourceTimeline
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.PausedFrames
import com.vecvel.danaview.editor.engine.preview.fallback.RuleFrameMath
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RenderedFrameParityTest {
    /** A source with the sample table [pts] (ascending, presentation order). */
    private class TableTimeline(val pts: LongArray, private val durUs: Long) : SourceTimeline {
        // RuleFrameMath.rule is the live decks' lookup: past the last frame it answers the last one.
        override fun ruleFramePtsUs(uri: String, sourceUs: Long): Long = RuleFrameMath.rule(pts, sourceUs)

        override fun durationUs(uri: String): Long? = durUs
    }

    private enum class Pts { FLOOR, ROUND }

    /** [n] frames at [fps]: floor (mp4 timescale 600, the counters) or round of j·1e6/fps, plus [offsetUs]. */
    private fun table(fps: Int, n: Int, kind: Pts = Pts.FLOOR, offsetUs: Long = 0L): LongArray = LongArray(n) { j ->
        val num = j.toLong() * FrameGrid.MICROS
        offsetUs + when (kind) {
            Pts.FLOOR -> Math.floorDiv(num, fps.toLong())
            Pts.ROUND -> Math.floorDiv(2 * num + fps, 2L * fps)
        }
    }

    private val uri = "file:///fixtures/counter.mp4"

    /** A preview plan of [frames] output frames at [fps] with one media layer over [k0, k1) from source time [s0]. */
    private fun plan(fps: Int, frames: Long, k0: Long, k1: Long, s0: Long): RenderPlan {
        val g = FrameGrid.of(fps)
        val t0 = g.timeOfFrame(k0)
        val t1 = g.timeOfFrame(k1)
        val layer = PlanLayer(
            id = "L#v", z = 10, seq = 0, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md",
            map = listOf(MapSegment(t0, t1, s0, s0 + (t1 - t0))), base = PlanSize(640.0, 360.0),
        )
        val p = RenderPlan(
            rev = 1, target = PlanTarget.PREVIEW, canvas = PlanCanvas(640, 360, fps), durUs = g.timeOfFrame(frames),
            assets = mapOf("md" to PlanAsset(PlanAssetKind.VIDEO, uri, fp = "counter", w = 640, h = 360, durUs = 60_000_000L)),
            layers = listOf(layer), audio = emptyList(),
        )
        assertEquals("plan valid", emptyList<Any>(), PlanValidator.validate(p))
        return p
    }

    /** One frame reaching the compositor on the layer's sequence: its time and source index (null: a gap image). */
    private class Arrival(val timeUs: Long, val source: Int?)

    /**
     * The frames the layer's sequence feeds the compositor for the range plan [range] rendered from
     * [pts] (production mapping), minus the source frames in [lost].
     */
    private fun arrivals(range: RenderPlan, pts: LongArray, lost: Set<Int> = emptySet(), sourceDurUs: Long = pts.last() + 1): List<Arrival> {
        val export = RenderPreviewSpecs.exportPlan(range, null)
        val spec = CompositionMapper(TableTimeline(pts, sourceDurUs)).map(export, CompositionMapper.Options(useProxies = false))
        val out = FrameGrid.of(spec.outputFps)
        val seq = spec.layerSequences.single()
        val list = ArrayList<Arrival>()
        /** Image frames (gap or held still) at the output fps, on P(m), showing [source]. */
        fun images(item: ItemSpec, source: Int?) {
            var m = out.frameIndexNearest(item.startUs)
            while (true) {
                val t = out.platformTimeOfFrame(m)
                if (t >= item.endUs) break
                if (t >= item.startUs) list += Arrival(t, source)
                m++
            }
        }
        for (item in seq.items) {
            when {
                item.kind == ItemKind.MEDIA && item.hold -> {
                    // The held last source frame: Media3Composition draws its still at the output fps.
                    val j = java.util.Arrays.binarySearch(pts, item.clipStartUs)
                    assertTrue("the held frame is a source frame", j >= 0)
                    assertEquals("only the last source frame is held", pts.size - 1, j)
                    images(item, j)
                }
                item.kind == ItemKind.MEDIA -> {
                    assertNull("1× items carry no speed provider", item.speed)
                    for ((j, p) in pts.withIndex()) {
                        if (p < item.clipStartUs || p >= item.clipEndUs || j in lost) continue
                        list += Arrival(item.startUs + (p - item.clipStartUs), j)
                    }
                }
                // Gap (transparent image) frames at the output fps, on P(m).
                else -> images(item, null)
            }
        }
        return list.sortedBy { it.timeUs }
    }

    /** DefaultVideoCompositor's secondary choice at primary pts [p]: nearest, a tie takes the earlier frame. */
    private fun nearest(frames: List<Arrival>, p: Long): Arrival = frames.minWithOrNull(
        compareBy<Arrival> { kotlin.math.abs(it.timeUs - p) }.thenBy { it.timeUs },
    )!!

    /** The live rule frame (source index) of the range's layer at output frame [k]. */
    private fun live(range: RenderPlan, pts: LongArray, k: Long): Int {
        val layer = range.layers.single()
        val t = FrameGrid.of(range.canvas.fps).timeOfFrame(k)
        val rule = RuleFrameMath.rule(pts, PausedFrames.sourceTimeUs(layer, t))
        return java.util.Arrays.binarySearch(pts, rule)
    }

    /** Output frames of [range]'s layer: (k, rendered source index or null for a gap, live index). */
    private fun compare(range: RenderPlan, pts: LongArray, lost: Set<Int> = emptySet(), sourceDurUs: Long = pts.last() + 1): List<Triple<Long, Int?, Int>> {
        val g = FrameGrid.of(range.canvas.fps)
        val frames = arrivals(range, pts, lost, sourceDurUs)
        val layer = range.layers.single()
        val k0 = g.frameIndexOf(layer.t0)
        val k1 = g.frameIndexOf(layer.t1)
        return (k0 until k1).map { k -> Triple(k, nearest(frames, g.platformTimeOfFrame(k)).source, live(range, pts, k)) }
    }

    @Test
    fun aSameRateRenderShowsTheLiveRuleFrameAtEveryOutputFrame() {
        var checked = 0
        for (fps in listOf(24, 30, 60)) {
            val period = FrameGrid.MICROS / fps
            for (kind in Pts.values()) {
                for (offset in listOf(0L, 2 * FrameGrid.MICROS / fps)) {
                    val pts = table(fps, fps * 20, kind, offset)
                    for (j in listOf(0, 5, 120, fps * 6 + 15)) {
                        // On the grid (pts and the fixtures' floor(J·1e6/fps)), ±1 µs, inside the frame,
                        // and 98 µs inside both rule-tolerance edges.
                        val deltas = listOf(0L, 1L, -1L, period / 3, period / 2, period - 600L, -400L)
                        for (d in deltas) {
                            val s0 = pts[j] + d
                            if (s0 < 0) continue
                            for (k0 in listOf(0L, 1L, 2L, 3L, 7L)) {
                                val range = plan(fps, k0 + 45, k0, k0 + 40, s0)
                                val wrong = compare(range, pts).filter { (_, r, l) -> r != l }
                                assertEquals("fps $fps $kind offset $offset J $j delta $d k0 $k0: (k, render, live)", emptyList<Any>(), wrong)
                                checked++
                            }
                        }
                    }
                }
            }
        }
        assertTrue("cases checked: $checked", checked > 1000)
    }

    @Test
    fun theFixtureInPointsOfTheFailingRangesMapToTheRuleFrame() {
        // e2c6b71b: grid-cut 30 fps, range [31, 92) layer B (source frame 195 at range frame 0) and
        // range (31, 43) layer D (source frame 120 at range frame 3), both read 1 frame behind.
        val pts = table(30, 240)
        val b = plan(30, 62, 0, 31, Math.floorDiv(195L * FrameGrid.MICROS, 30L))
        val d = plan(30, 13, 3, 12, Math.floorDiv(120L * FrameGrid.MICROS, 30L))
        for ((range, at) in listOf(b to (26L to 221), d to (9L to 126))) {
            val rows = compare(range, pts)
            assertEquals("render = live at every frame", rows.map { it.third }, rows.map { it.second })
            assertEquals("the frame Windows checked", at.second, rows.single { it.first == at.first }.second)
        }
    }

    @Test
    fun aFrameLostBeforeTheCompositorShowsTheNextFrameNotThePrevious() {
        // With the counters' PTS table (timescale 600: floor), losing the wanted frame makes the
        // compositor pick the next frame (33 333 µs away) over the previous one (33 334 µs away).
        val pts = table(30, 240, Pts.FLOOR)
        val b = plan(30, 62, 0, 31, Math.floorDiv(195L * FrameGrid.MICROS, 30L))
        val d = plan(30, 13, 3, 12, Math.floorDiv(120L * FrameGrid.MICROS, 30L))
        assertEquals(222, compare(b, pts, lost = setOf(221)).single { it.first == 26L }.second)
        assertEquals(127, compare(d, pts, lost = setOf(126)).single { it.first == 9L }.second)
        // Two consecutive lost frames are needed for a -1 there.
        assertEquals(220, compare(b, pts, lost = setOf(221, 222)).single { it.first == 26L }.second)
        // (With a round() table the two neighbours tie and Media3 takes the earlier one: the
        // direction of a lost frame depends on the source's PTS rounding, which is why the counters'
        // table is pinned above.)
        val roundPts = table(30, 240, Pts.ROUND)
        assertEquals(125, compare(d, roundPts, lost = setOf(126)).single { it.first == 9L }.second)
    }

    @Test
    fun mixedRatesFollowTheNearestFrameNeverAnEarlierOne() {
        for ((source, project) in listOf(24 to 30, 60 to 30)) {
            val pts = table(source, source * 20)
            var ahead = 0
            for (j in listOf(0, 13, source * 3)) {
                for (k0 in listOf(0L, 1L, 2L)) {
                    val range = plan(project, k0 + 45, k0, k0 + 40, pts[j])
                    for ((k, r, l) in compare(range, pts)) {
                        val diff = requireNotNull(r) { "$source→$project k $k shows a gap" } - l
                        assertTrue("$source→$project J $j k0 $k0 k $k: render $r live $l", diff == 0 || diff == 1)
                        if (diff == 1) ahead++
                    }
                }
            }
            if (source < project) assertTrue("$source→$project: Media3 shows the nearer next frame somewhere (V-N15)", ahead > 0)
            else assertEquals("$source→$project: exact", 0, ahead)
        }
    }

    @Test
    fun aLayerPastItsSourceEndHoldsTheLastSourceFrameExactlyAsLive() {
        // An 8 s counter (n = 8·fps frames, the file 8 s long) and layers wanting frames past it.
        // (first source frame, layer start k0, layer frames): the six-layer range's K4 and K5
        // (130 and 160 over 120 frames at 30 fps, scaled to the rate), a layer starting on the last
        // frame, one starting past the end (held throughout), and one ending exactly at the source
        // end (no overrun: the clip plays to the end, the control).
        val counterDurUs = 8_000_000L
        var heldFrames = 0
        var cases = 0
        for (fps in listOf(24, 30, 60)) {
            val n = 8 * fps
            for (kind in Pts.values()) {
                val pts = table(fps, n, kind)
                val layouts = listOf(
                    Triple(n - 110, 0L, 120L),
                    Triple(n - 80, 1L, 120L),
                    Triple(n - 30, 2L, 45L),
                    Triple(n - 1, 0L, 12L),
                    Triple(n + 5, 3L, 10L),
                    Triple(n - 15, 0L, 15L),
                )
                for ((first, k0, frames) in layouts) {
                    val s0 = Math.floorDiv(first.toLong() * FrameGrid.MICROS, fps.toLong())
                    val range = plan(fps, k0 + frames + 5, k0, k0 + frames, s0)
                    val rows = compare(range, pts, sourceDurUs = counterDurUs)
                    val wrong = rows.filter { (_, r, l) -> r != l }
                    assertEquals("fps $fps $kind first $first k0 $k0: (k, render, live)", emptyList<Any>(), wrong)
                    // Every frame the layer wants at or past the last source frame shows the last one.
                    for ((k, r, _) in rows) {
                        val want = first + (k - k0).toInt()
                        if (want >= n - 1) {
                            assertEquals("fps $fps $kind first $first k $k holds the last frame", n - 1, r)
                            heldFrames++
                        }
                    }
                    cases++
                }
            }
        }
        assertEquals(36, cases)
        assertTrue("frames held: $heldFrames", heldFrames > 300)
    }

    @Test
    fun theSixLayerRangeLayersK4AndK5MapToAPlayedPartAndAHeldLastFrame() {
        // K4: counter frames 130.. over 120 range frames at 30 fps; K5: 160.. (the counter has 240).
        val pts = table(30, 240)
        for ((first, kH) in listOf(130 to 109L, 160 to 79L)) {
            val range = plan(30, 125, 0, 120, Math.floorDiv(first.toLong() * FrameGrid.MICROS, 30L))
            val export = RenderPreviewSpecs.exportPlan(range, null)
            val spec = CompositionMapper(TableTimeline(pts, 8_000_000L)).map(export, CompositionMapper.Options(useProxies = false))
            val items = spec.layerSequences.single().items.filter { it.kind == ItemKind.MEDIA }
            assertEquals("K$first: a played part and a held part", 2, items.size)
            val (played, held) = items
            assertNull("K$first: the played part runs at 1x (no SpeedFit slow-down)", played.speed)
            assertEquals("K$first: played to the frame before the hold", kH, played.k1)
            assertEquals("K$first: 1x clip", played.durationUs, played.clipEndUs - played.clipStartUs)
            assertTrue("K$first: the played clip ends before the last frame", played.clipEndUs <= pts.last())
            assertTrue("K$first: held", held.hold)
            assertEquals("K$first: the hold starts where the play ends", played.endUs, held.startUs)
            assertEquals("K$first: the held frame is the last one", pts.last(), held.clipStartUs)
            assertEquals("K$first: held to the layer's end", 120L, held.k1)
        }
    }
}
