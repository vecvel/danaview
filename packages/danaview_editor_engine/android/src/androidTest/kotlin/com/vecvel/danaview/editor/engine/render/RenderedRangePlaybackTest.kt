// OWNER: AND-18
//
// AND-18 acceptance on the emulator (ARCH D-45, §13.3; BUILD_PLAN AND-18), every frame identified by
// its pts (P(k), D-35) and checked through ENG-05's counter barcodes:
// - a rendered range matches the live composition at preview size: the render file (H.264,
//   all-intra, video only, frame j at P(j)) shows the rule frame of every layer in every frame, and
//   the frames playback shows from it match the live paused-exact frames (Y-plane SSIM ≥ 0.99);
// - 0 wrong frames across range boundaries during playback at 24/30/60 fps (AND-01's grid-cut
//   composition, two rendered ranges whose edges fall next to its cuts);
// - a param patch inside a range falls back to the live decks: no frame of the stale render is
//   shown after the patch is published beyond the rebuild latency (measured, ≤ 2 frames), and every
//   later frame is the live composition of the patched plan;
// - a 6-layer chroma-key range on the minimal/low tier budget (2 live slots) plays from its cache
//   with ≤ 2% dropped frames where live playback shows 4 layers as still frames (emulator numbers).
// Emulator numbers only, logged under AND18; device numbers are QA-04's.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.fallback.Region
import com.vecvel.danaview.editor.engine.fallback.Timings
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.precompose.Compare
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import com.vecvel.danaview.editor.engine.support.decode
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RenderedRangePlaybackTest {
    private val q3 = FallbackPlans.QUADRANTS.take(3)

    /** Mismatches of frame [f] against [plan] in the quadrants of slots 0..2. */
    private fun mismatches(plan: RenderPlan, k: Long, readings: Map<String, Int?>, pts: LongArray): List<String> {
        val out = ArrayList<String>()
        for (q in 0 until 3) {
            val want = FallbackPlans.expectedIn(plan, q, k, pts)
            val got = readings["s$q"]
            if (want != got) out += "k=$k s$q want=$want got=$got"
        }
        return out
    }

    @Test
    fun aRenderedRangeMatchesTheLiveCompositionAtPreviewSize() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        val first = 30L
        val end = 90L
        val n = (end - first).toInt()
        RangeHarness("and18_match", plan, q3).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            val (file, ms) = h.rig.render(RangeCut.cut(plan, first, end), "match")
            val rf = RenderedFile(file)
            log18("render [${first}, $end) of grid-cut 30 fps (emulator): $rf in $ms ms")
            assertEquals("one video track", 1, rf.videoTracks)
            assertEquals("video only", 0, rf.audioTracks)
            assertEquals(640, rf.width)
            assertEquals(360, rf.height)
            assertTrue("every range frame is in the file: $rf", rf.samples >= n)
            assertEquals("all-intra: $rf", rf.samples, rf.syncSamples)
            val g = FrameGrid.of(fps)
            val offGrid = (0 until n).filter { j -> kotlin.math.abs(rf.pts[j] - g.platformTimeOfFrame(j.toLong())) > 1 }
            assertEquals("frame j at P(j): ${offGrid.take(5).map { "$it:${rf.pts[it]}" }}", emptyList<Int>(), offGrid)
            // Every frame of the file shows each layer's rule frame (barcode exact).
            val bitmaps = rf.frames(0, n)
            val fileWrong = ArrayList<String>()
            for ((j, b) in bitmaps.withIndex()) {
                val readings = q3.associate { it.name to FrameBarcode.decode(b, it.barcode) }
                fileWrong += mismatches(plan, first + j, readings, pts)
            }
            assertEquals("render file barcodes", emptyList<String>(), fileWrong)
            // Playback from the cache vs the live paused-exact frames at the same output frames.
            val samples = listOf(0L, 1L, 9L, 20L, 33L, 47L, 58L, 59L).map { first + it }
            h.bind(listOf(h.rig.msg(first, end, h.grid, file)))
            h.sink.keep.addAll(samples)
            assertTrue("warm-up", h.seekExact(0, 30_000) >= 0)
            h.sink.clear()
            assertTrue("played to the end", h.playToEnd(0, 60_000))
            Thread.sleep(150)
            val played = h.sink.frames.filter { it.k in samples && it.rgba != null }.associateBy { it.k }
            val stats = h.stats()
            assertTrue("range frames played from the file (${stats.rangeFrames})", stats.rangeFrames >= n / 2)
            val ssimPlayback = ArrayList<Double>()
            val ssimFile = ArrayList<Double>()
            for (k in samples) {
                assertTrue("live seek $k", h.seekExact(k) >= 0)
                val live = h.sink.awaitK(k)
                val liveBmp = rgbaBitmap(requireNotNull(live.rgba), 640, 360)
                val liveY = Compare.luma(liveBmp)
                ssimFile += Compare.ssim(liveY, Compare.luma(bitmaps[(k - first).toInt()]), 640, 360)
                played[k]?.let { ssimPlayback += Compare.ssim(liveY, Compare.luma(rgbaBitmap(it.rgba!!, 640, 360)), 640, 360) }
            }
            val line = "rendered vs live at 640x360 (emulator): playback-from-cache SSIM ${ssimPlayback.map { "%.4f".format(it) }} " +
                "(${played.size}/${samples.size} sampled frames presented), file-frame SSIM ${ssimFile.map { "%.4f".format(it) }}"
            log18(line)
            assertTrue("sampled range frames presented during playback: $line", played.size >= samples.size / 2)
            assertTrue("playback from the cache: SSIM >= 0.99: $line", ssimPlayback.all { it >= 0.99 })
            assertTrue("render file frames: SSIM >= 0.99: $line", ssimFile.all { it >= 0.99 })
        }
    }

    /** Two ranges of the grid-cut plan at [fps] whose edges sit next to its cuts. */
    private fun ranges(plan: RenderPlan): List<Pair<Long, Long>> {
        val d = FrameGrid.of(plan.canvas.fps).frameIndexOf(plan.durUs)
        val a0 = FallbackPlans.cutAt(d, 0.20, 0)
        val a1 = FallbackPlans.cutAt(d, 0.45, 1)
        val b0 = FallbackPlans.cutAt(d, 0.60, 2)
        val b1 = FallbackPlans.cutAt(d, 0.85, 0)
        return listOf(a0 to a1, b0 to b1)
    }

    @Test
    fun noWrongFrameAcrossRangeBoundariesAt24_30_60() {
        val report = StringBuilder()
        for (fps in listOf(24, 30, 60)) {
            val plan = FallbackPlans.gridCut(fps)
            RangeHarness("and18_bounds_$fps", plan, q3).use { h ->
                val pts = FallbackPlans.pts(h.engine.ctx, fps)
                val rs = ranges(plan)
                val msgs = rs.mapIndexed { i, (a, b) -> h.rig.msg(a, b, h.grid, h.rig.render(RangeCut.cut(plan, a, b), "b${fps}_$i").first) }
                val binding = h.bind(msgs)
                assertTrue("warm-up", h.seekExact(0, 30_000) >= 0)
                h.sink.clear()
                h.host.dropped.clear()
                val ended = h.playToEnd(0, plan.durUs / 1000 + 60_000)
                Thread.sleep(200)
                val shown = h.sink.frames.toList()
                val bad = shown.flatMap { mismatches(plan, it.k, it.readings, pts) }
                val ks = shown.map { it.k }.toSet()
                val inRange = shown.count { f -> rs.any { (a, b) -> f.k in a until b } }
                val edges = rs.flatMap { listOf(it.first, it.second) }
                val bothSides = edges.count { (it - 1) in ks && it in ks }
                val stats = h.stats()
                val swap = binding.swap.stats()
                val line = "range boundaries $fps fps (emulator): presented ${ks.size}/${fps * 4} ($inRange from 2 rendered ranges ${rs}), " +
                    "dropped ${h.host.dropped.size}, range frames ${stats.rangeFrames}, swap entered ${swap.entered} left ${swap.left}, " +
                    "boundaries seen on both sides $bothSides/${edges.size}, composite ${Timings(stats.compositeMs)}, wrong ${bad.size} ${bad.take(6)}"
                log18(line)
                report.appendLine(line)
                assertTrue("ended: $line", ended)
                assertEquals("no wrong frame at $fps fps: $line", emptyList<String>(), bad)
                assertTrue("presented frames increase", shown.zipWithNext().all { (a, b) -> b.k > a.k })
                assertTrue("both ranges played from their files: $line", swap.entered >= 2 && swap.left >= 2 && stats.rangeFrames >= inRange)
                assertTrue("most range frames presented: $line", inRange * 2 >= rs.sumOf { it.second - it.first })
            }
        }
        log18(report.toString())
    }

    @Test
    fun aParamPatchInsideARangeFallsBackToLiveOnTheNextFrame() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        val first = 15L
        val end = 105L
        RangeHarness("and18_patch", plan, q3).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            val file = h.rig.render(RangeCut.cut(plan, first, end), "patch").first
            val binding = h.bind(listOf(h.rig.msg(first, end, h.grid, file)))
            // The patch: slot 2's layer F (bottom-left, from about 0.64 of the plan) fades out
            // (op 0, a param-only change: no structural rebuild). Live then shows the background in
            // the bottom-left quadrant; the stale render would still show F's barcode.
            val f = plan.layer("F#v")!!
            val patched = plan.copy(rev = 2, layers = plan.layers.map { if (it.id == "F#v") it.copy(xf = it.xf.copy(op = 0.0)) else it })
            val fStart = h.grid.frameIndexOf(f.t0)
            assertTrue("F starts inside the range", fStart in first + 10 until end - 20)
            assertTrue("warm-up", h.seekExact(0, 30_000) >= 0)
            h.sink.clear()
            var publishedAtNs = 0L
            var patchK = -1L
            val ended = h.playToEnd(0, 60_000) {
                // Publish once playback shows F from the cache for a few frames.
                val last = h.sink.frames.lastOrNull() ?: return@playToEnd false
                if (last.k < fStart + 3) return@playToEnd false
                patchK = last.k
                publishedAtNs = System.nanoTime()
                h.publish(patched, setOf("F#v"))
                true
            }
            Thread.sleep(200)
            assertTrue("ended", ended)
            val shown = h.sink.frames.toList()
            val after = shown.filter { it.atNs > publishedAtNs }
            val stale = after.filter { it.k < end && it.readings["s2"] != null }
            val staleCount = after.takeWhile { it.k < end && it.readings["s2"] != null }.size
            val laterWrong = after.drop(staleCount).flatMap { mismatches(patched, it.k, it.readings, pts) }
            val beforeWrong = shown.filter { it.atNs <= publishedAtNs }.flatMap { mismatches(plan, it.k, it.readings, pts) }
            val stats = h.stats()
            val line = "param patch at k=$patchK inside range [$first, $end) (emulator): ${after.size} frames presented after the patch, " +
                "stale render frames after it $staleCount (first live frame k=${after.getOrNull(staleCount)?.k}), " +
                "swap dropped ${binding.swap.stats().dropped}, rebuilds ${binding.rebuilds}, dropped frames ${h.host.dropped.size}, range frames ${stats.rangeFrames}"
            log18(line)
            assertEquals("before the patch every frame is right: $line", emptyList<String>(), beforeWrong)
            assertEquals("the range was dropped", 1, binding.swap.stats().dropped)
            assertTrue("the range is gone until the next set", binding.swap.isEmpty)
            assertTrue("frames after the patch: $line", after.size >= 10)
            assertTrue("at most the rebuild latency (2 frames) of the stale render: $line", staleCount <= 2)
            assertEquals("no stale frame after the fallback: $line", staleCount, stale.size)
            assertEquals("every later frame is the live patched composition: $line", emptyList<String>(), laterWrong)
        }
    }

    /** 6 overlapping chroma-keyed counter layers in a 3 × 2 grid (one slot each). */
    private fun sixKeyedLayers(fps: Int, frames: Long): RenderPlan {
        val g = FrameGrid.of(fps)
        val t1 = g.timeOfFrame(frames)
        val layers = (0 until 6).map { i ->
            val cx = 640.0 / 3 * (i % 3) + 640.0 / 6
            val cy = 180.0 * (i / 3) + 90.0
            val s0 = Math.floorDiv((10L + 30L * i) * 1_000_000L, fps.toLong())
            PlanLayer(
                id = "K$i#v", z = 10 + i, seq = i, t0 = 0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "counter",
                map = listOf(MapSegment(0, t1, s0, s0 + t1)), base = PlanSize(640.0, 360.0),
                xf = PlanTransform(cx = cx, cy = cy, s = 1.0 / 3),
                fx = PlanEffects(chroma = PlanChroma(key = 0xFF00FF00.toInt(), sim = 0.3, smooth = 0.1, spill = 0.2)),
            )
        }
        return FallbackPlans.plan(fps, frames, layers)
    }

    private fun cells(): List<Region> = (0 until 6).map { i ->
        val w = 640 / 3
        Region("c$i", w * (i % 3), 180 * (i / 3), w, 180)
    }

    @Test
    fun aSixLayerChromaKeyRangePlaysFromItsCacheOnTheMinimalTierBudget() {
        val fps = 30
        val frames = 120L
        val plan = sixKeyedLayers(fps, frames)
        // Minimal/low tier live budget: 2 slots (D-43(e)); the other 4 layers are stills during live playback.
        val config = ContingencyPreviewBackend.Config(liveBudget = 2)
        RangeHarness("and18_six", plan, cells(), config).use { h ->
            // Live playback first (stills for the over-budget layers).
            assertTrue("warm-up", h.seekExact(0, 60_000) >= 0)
            h.host.dropped.clear()
            h.sink.clear()
            val liveEnded = h.playToEnd(0, 60_000)
            Thread.sleep(200)
            val live = h.stats()
            val liveShown = h.sink.frames.size
            val liveDropped = h.host.dropped.size
            // Render the whole timeline as one range and play it from the cache.
            val (file, ms) = h.rig.render(RangeCut.cut(plan, 0, frames), "six")
            h.bind(listOf(h.rig.msg(0, frames, h.grid, file)))
            assertTrue("seek", h.seekExact(0, 60_000) >= 0)
            h.host.dropped.clear()
            h.sink.clear()
            val before = h.stats()
            val cachedEnded = h.playToEnd(0, 60_000)
            Thread.sleep(200)
            val cached = h.stats()
            val shown = h.sink.frames.toList()
            val dropped = h.host.dropped.size
            val rangeFrames = cached.rangeFrames - before.rangeFrames
            val dropPct = 100.0 * dropped / frames
            // The cache shows every layer moving: each cell's barcode advances with k.
            val cellsMoving = (0 until 6).count { i ->
                val values = shown.mapNotNull { it.readings["c$i"] }
                values.size >= shown.size / 2 && values.zipWithNext().all { (a, b) -> b >= a } && values.last() > values.first()
            }
            val line = "6-layer chroma key, liveBudget 2 (emulator): live playback presented $liveShown/$frames, dropped $liveDropped, " +
                "stills fetched ${live.stillsFetched}; render ${RenderedFile(file)} in $ms ms; cached playback presented ${shown.size}/$frames, " +
                "dropped $dropped (%.1f%%), range frames $rangeFrames, cells moving $cellsMoving/6, composite ${Timings(cached.compositeMs)}".format(dropPct)
            log18(line)
            assertTrue("live ended", liveEnded)
            assertTrue("live playback used stills for the over-budget layers: $line", live.stillsFetched > 0)
            assertTrue("cached ended", cachedEnded)
            assertTrue("the cache played the range: $line", rangeFrames >= frames - 2)
            assertTrue("<= 2% dropped from the cache: $line", dropPct <= 2.0)
            assertEquals("every layer moves in the cached playback: $line", 6, cellsMoving)
        }
    }
}
