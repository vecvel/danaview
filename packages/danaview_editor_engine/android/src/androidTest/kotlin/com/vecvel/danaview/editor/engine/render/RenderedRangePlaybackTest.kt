// OWNER: AND-18
//
// AND-18 acceptance on the emulator (ARCH D-45, §13.3; BUILD_PLAN AND-18), every frame identified by
// its pts (P(k), D-35) and checked through ENG-05's counter barcodes:
// - a rendered range matches the live composition at preview size: the render file (H.264,
//   all-intra, video only, frame j at P(j)) shows the rule frame of every layer in every frame, and
//   the frames playback shows from it match the live paused-exact frames (Y-plane SSIM ≥ 0.99);
// - 0 wrong frames across range boundaries during playback at 24/30/60 fps (AND-01's grid-cut
//   composition, two rendered ranges cut at its layer edges as CORE-37 cuts them), on the original
//   counters and on light 640x360 all-intra copies of them (rendered by the job itself) with which
//   the emulator presents the frames on both sides of the edges;
// - a param patch inside a range falls back to the live decks on the next frame: no frame
//   composited after the patched snapshot became visible shows the stale render (the backend asks
//   the swap about every range frame), and every such frame is the live composition of the
//   patched plan;
// - a 6-layer chroma-key range on the minimal/low tier budget (2 live slots) plays from its cache
//   where live playback shows 4 layers as still frames, every layer advancing (a backward step is a
//   wrong frame); the emulator's drop rate is recorded, and with DV_PERF_STRICT=1 must meet the
//   ≤ 2% budget or beat live playback (the budget is a device number, QA-04).
// Frame counts (how many frames playback presents) are GPU-speed numbers: their device minimums
// apply only with DV_PERF_STRICT=1 (harness/PerfGate.kt); without it a smaller non-vacuity minimum.
// No assertion retries or tolerates a wrong frame: when Media3's multi-input compositor (AND-08's
// export path) composites a stale input frame into a render on the emulator, these tests fail.
// Playback on the x86_64 emulator drops many frames (AND-16's own grid-cut playback presents
// 20-65% of frames here), so playback assertions are correctness (no wrong frame) plus
// non-vacuity (frames of every range and of the live parts were checked).
// Emulator numbers only, logged under AND18; device numbers are QA-04's.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.fallback.Region
import com.vecvel.danaview.editor.engine.fallback.Timings
import com.vecvel.danaview.editor.engine.harness.PerfGate
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.precompose.Compare
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
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

    /** As [mismatches], with a fully transparent layer (op 0) expected as the background. */
    private fun mismatchesVisible(plan: RenderPlan, k: Long, readings: Map<String, Int?>, pts: LongArray): List<String> {
        val t = FrameGrid.of(plan.canvas.fps).timeOfFrame(k)
        val out = ArrayList<String>()
        for (q in 0 until 3) {
            val l = plan.layers.firstOrNull { it.kind == PlanLayerKind.MEDIA && it.seq == q && it.covers(t) }
            val want = if (l != null && l.xf.op == 0.0) null else FallbackPlans.expectedIn(plan, q, k, pts)
            val got = readings["s$q"]
            if (want != got) out += "k=$k s$q want=$want got=$got"
        }
        return out
    }

    @Test
    fun aRenderedRangeMatchesTheLiveCompositionAtPreviewSize() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        // CORE-37 cuts ranges at layer edges: [31, 92) runs from B's start to C's start.
        val first = 31L
        val end = 92L
        val n = (end - first).toInt()
        RangeHarness("and18_match", plan, q3).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            fun fileMismatches(f: java.io.File): Pair<List<String>, List<android.graphics.Bitmap>> {
                val bitmaps = RenderedFile(f).frames(0, n)
                val wrong = ArrayList<String>()
                for ((j, b) in bitmaps.withIndex()) {
                    val readings = q3.associate { it.name to FrameBarcode.decode(b, it.barcode) }
                    wrong += mismatches(plan, first + j, readings, pts)
                }
                return wrong to bitmaps
            }
            val (file, ms) = h.rig.render(RangeCut.cut(plan, first, end), "match")
            val (fileWrong, bitmaps) = fileMismatches(file)
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
            assertEquals("render file barcodes", emptyList<String>(), fileWrong)
            // Playback from the cache vs the live paused-exact frames at the same output frames:
            // the pixels of every third range frame presented during playback are kept.
            val fileSamples = listOf(0L, 1L, 9L, 20L, 33L, 47L, 59L, 60L)
            h.bind(listOf(h.rig.msg(first, end, h.grid, file)))
            h.sink.keep.addAll((first + 1 until end step 3).toList())
            // Playback starts inside the range (the range deck pre-rolls like a standby deck).
            assertTrue("warm-up", h.seekExact(first, 30_000) >= 0)
            h.sink.awaitK(first)
            Thread.sleep(200)
            h.sink.clear()
            assertTrue("played to the end", h.playToEnd(first, 60_000))
            Thread.sleep(150)
            val played = h.sink.frames.filter { it.k in first until end && it.rgba != null }.associateBy { it.k }
            val playedWrong = h.sink.frames.flatMap { mismatches(plan, it.k, it.readings, pts) }
            val stats = h.stats()
            val compareKs = played.keys.sorted().take(12)
            h.sink.keep.clear()
            h.sink.keep.addAll(compareKs + fileSamples.map { first + it })
            val ssimPlayback = ArrayList<Double>()
            val ssimFile = ArrayList<Double>()
            for (k in (compareKs + fileSamples.map { first + it }).distinct().sorted()) {
                h.sink.clear()
                assertTrue("live seek $k", h.seekExact(k) >= 0)
                val live = h.sink.awaitK(k)
                val liveY = Compare.luma(rgbaBitmap(requireNotNull(live.rgba), 640, 360))
                if (k - first in fileSamples) ssimFile += Compare.ssim(liveY, Compare.luma(bitmaps[(k - first).toInt()]), 640, 360)
                played[k]?.let { ssimPlayback += Compare.ssim(liveY, Compare.luma(rgbaBitmap(it.rgba!!, 640, 360)), 640, 360) }
            }
            val line = "rendered vs live at 640x360 (emulator): ${stats.rangeFrames} range frames played from the file, " +
                "playback-from-cache SSIM ${ssimPlayback.map { "%.4f".format(it) }}, file-frame SSIM ${ssimFile.map { "%.4f".format(it) }}"
            log18(line)
            assertEquals("no wrong frame during playback", emptyList<String>(), playedWrong)
            // How many range frames playback presents is a GPU-speed number (DV_PERF_STRICT=1: 3).
            val minCompared = PerfGate.atLeast(3, 1)
            assertTrue("range frames presented from the file and compared (>= $minCompared, ${PerfGate.mode}): $line", ssimPlayback.size >= minCompared && stats.rangeFrames >= ssimPlayback.size)
            assertTrue("playback from the cache: SSIM >= 0.99: $line", ssimPlayback.all { it >= 0.99 })
            assertTrue("render file frames: SSIM >= 0.99: $line", ssimFile.size == fileSamples.size && ssimFile.all { it >= 0.99 })
        }
    }

    /** The layer edges of [plan] inside it (CORE-37 splits ranges there), sorted. */
    private fun edges(plan: RenderPlan): List<Long> {
        val g = FrameGrid.of(plan.canvas.fps)
        val d = g.frameIndexOf(plan.durUs)
        return plan.layers.flatMap { listOf(g.frameIndexOf(it.t0), g.frameIndexOf(it.t1)) }.filter { it in 1 until d }.toSortedSet().toList()
    }

    /** Two ranges of the grid-cut plan between its layer edges (each edge at k ≡ 1 or 2 mod 3). */
    private fun ranges(plan: RenderPlan): List<Pair<Long, Long>> {
        val e = edges(plan)
        return listOf(e[0] to e[2], e[3] to e[5])
    }

    /**
     * One boundary run on [plan] (two rendered ranges): a full play, then (with [edgePlays]) short
     * plays from two frames before each range edge. Returns the edges crossed frame to frame.
     */
    private fun boundaryRun(name: String, plan: RenderPlan, edgePlays: Boolean, pts: (RangeHarness) -> LongArray, report: StringBuilder): Int {
        val fps = plan.canvas.fps
        var crossed = 0
        RangeHarness(name, plan, q3).use { h ->
            val table = pts(h)
            val rs = ranges(plan)
            val msgs = rs.mapIndexed { i, (a, b) -> h.rig.msg(a, b, h.grid, h.rig.render(RangeCut.cut(plan, a, b), "${name}_$i").first) }
            val binding = h.bind(msgs)
            assertTrue("warm-up", h.seekExact(0, 30_000) >= 0)
            h.sink.awaitK(0)
            Thread.sleep(200)
            h.sink.clear()
            h.host.dropped.clear()
            val ended = h.playToEnd(0, plan.durUs / 1000 + 60_000)
            Thread.sleep(200)
            val shown = h.sink.frames.toList()
            val dropped = h.host.dropped.size
            val stats = h.stats()
            val swap = binding.swap.stats()
            val edges = rs.flatMap { listOf(it.first, it.second) }
            val runs = ArrayList<List<Shown>>()
            runs += shown
            if (edgePlays) {
                for (e in edges) {
                    assertTrue("seek ${e - 2}", h.seekExact(e - 2) >= 0)
                    h.sink.awaitK(e - 2)
                    Thread.sleep(150)
                    h.sink.clear()
                    h.play(e - 2)
                    val until = System.currentTimeMillis() + 2_000
                    while (System.currentTimeMillis() < until && h.sink.frames.none { it.k >= e + 2 }) Thread.sleep(5)
                    h.pause()
                    Thread.sleep(100)
                    val run = h.sink.frames.toList()
                    assertTrue("presented frames increase around $e", run.zipWithNext().all { (x, y) -> y.k > x.k })
                    runs += run
                }
            }
            val all = runs.flatten()
            val bad = all.flatMap { mismatches(plan, it.k, it.readings, table) }
            val ks = shown.map { it.k }.toSet()
            val inRange = shown.count { f -> rs.any { (x, y) -> f.k in x until y } }
            // An edge is crossed frame to frame when one play presented k − 1 and then k.
            crossed = edges.count { e -> runs.any { run -> run.zipWithNext().any { (x, y) -> x.k == e - 1 && y.k == e } } }
            val line = "range boundaries $name (emulator): full play presented ${ks.size}/${fps * 4} ($inRange from 2 rendered ranges $rs), " +
                "dropped $dropped, range frames ${stats.rangeFrames}, swap entered ${swap.entered} left ${swap.left}, composite ${Timings(stats.compositeMs)}" +
                (if (edgePlays) "; edge plays ${all.size - shown.size} frames" else "") +
                "; edges crossed frame to frame $crossed/${edges.size}; wrong ${bad.size} ${bad.take(6)}"
            log18(line)
            report.appendLine(line)
            assertTrue("ended: $line", ended)
            assertEquals("no wrong frame: $line", emptyList<String>(), bad)
            assertTrue("presented frames increase: $line", shown.zipWithNext().all { (x, y) -> y.k > x.k })
            assertTrue("both ranges played from their files: $line", swap.entered >= 2 && swap.left >= 2 && stats.rangeFrames >= inRange)
            // Non-vacuous on a slow emulator: frames from each range and live frames were checked.
            assertTrue("frames of each range presented: $line", rs.all { (x, y) -> shown.any { it.k in x until y } })
            val minLive = PerfGate.atLeast(5, 1)
            assertTrue("live frames presented (>= $minLive, ${PerfGate.mode}): $line", shown.count { f -> rs.none { (x, y) -> f.k in x until y } } >= minLive)
        }
        return crossed
    }

    /**
     * The counter of [fps] (ENG-05) re-rendered at 640x360 all-intra by the render-preview job (frame
     * j shows counter frame j): a light source for the live decks of the boundary runs, since the
     * 720p/1080p B-frame originals make the emulator drop most live frames next to the edges.
     */
    private fun lightCounter(fps: Int): PlanAsset {
        val frames = (fps * 8).toLong()
        val plan = FallbackPlans.plan(fps, frames, listOf(FallbackPlans.mainLayer(fps, frames, offset = 0)))
        var asset: PlanAsset? = null
        RangeHarness("and18_light_$fps", plan, emptyList()).use { h ->
            val file = h.rig.render(RangeCut.cut(plan, 0, frames), "light_$fps").first
            asset = PlanAsset(PlanAssetKind.VIDEO, "file://" + file.absolutePath, fp = "light-counter$fps", w = 640, h = 360)
        }
        return asset!!
    }

    @Test
    fun noWrongFrameAcrossRangeBoundariesAt24_30_60() {
        val report = StringBuilder()
        val crossed = HashMap<Int, Int>()
        for (fps in listOf(24, 30, 60)) {
            // The originals (heavy live decks): correctness and the emulator's drop numbers.
            val plan = FallbackPlans.gridCut(fps)
            boundaryRun("orig_$fps", plan, edgePlays = false, pts = { FallbackPlans.pts(it.engine.ctx, fps) }, report = report)
            // Light sources: the frames on both sides of the edges get presented.
            val light = lightCounter(fps)
            val lightPlan = plan.copy(assets = mapOf("counter" to light))
            crossed[fps] = boundaryRun("light_$fps", lightPlan, edgePlays = true, pts = { SourceFrameIndex(it.engine.ctx.appContext).frameTimes(light.uri) }, report = report)
        }
        log18(report.toString())
        // Frame-adjacent crossings depend on the emulator presenting consecutive frames (it rarely
        // does at 60 fps); every presented frame was checked above. Device adjacency: QA-04.
        assertTrue("range edges crossed frame to frame: $crossed\n$report", crossed.values.sum() >= 1)
    }

    @Test
    fun aParamPatchInsideARangeFallsBackToLiveOnTheNextFrame() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        // From D's start to the end of the plan (layer edges, as CORE-37 cuts them).
        val first = edges(plan)[1]
        val end = FrameGrid.of(fps).frameIndexOf(plan.durUs)
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
            h.sink.awaitK(0)
            Thread.sleep(200)
            h.sink.clear()
            var lastBefore = -1L
            var patchK = -1L
            val ended = h.playToEnd(0, 60_000) {
                // Publish once playback shows F from the cache for a few frames.
                val last = h.sink.frames.lastOrNull() ?: return@playToEnd false
                if (last.k < fStart + 3) return@playToEnd false
                patchK = last.k
                lastBefore = h.publishBetweenFrames(patched, setOf("F#v"))
                true
            }
            Thread.sleep(200)
            assertTrue("ended", ended)
            val shown = h.sink.frames.toList()
            // Playback presents increasing k: frames after lastBefore were composited after the patch.
            val after = shown.filter { it.k > lastBefore }
            val stale = after.filter { it.k < end && it.readings["s2"] != null }
            val afterWrong = after.flatMap { mismatchesVisible(patched, it.k, it.readings, pts) }
            val beforeWrong = shown.filter { it.k <= lastBefore }.flatMap { mismatches(plan, it.k, it.readings, pts) }
            val stats = h.stats()
            val line = "param patch at k=$patchK inside range [$first, $end) (emulator): last frame composited before it k=$lastBefore, " +
                "${after.size} frames presented after it (first k=${after.firstOrNull()?.k}), stale render frames after it ${stale.size} ${stale.take(3).map { it.k }}, " +
                "swap dropped ${binding.swap.stats().dropped}, rebuilds ${binding.rebuilds}, dropped frames ${h.host.dropped.size}, range frames ${stats.rangeFrames}"
            log18(line)
            assertTrue("published during playback inside the range: $line", lastBefore in fStart until end)
            assertEquals("before the patch every frame is right: $line", emptyList<String>(), beforeWrong)
            assertEquals("the range was dropped", 1, binding.swap.stats().dropped)
            assertTrue("the range is gone until the next set", binding.swap.isEmpty)
            val minAfter = PerfGate.atLeast(5, 1)
            assertTrue("frames after the patch (>= $minAfter, ${PerfGate.mode}): $line", after.size >= minAfter)
            assertEquals("no frame of the stale render after the patch (live on the next frame): $line", emptyList<Long>(), stale.map { it.k })
            assertEquals("every later frame is the live patched composition: $line", emptyList<String>(), afterWrong)
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

    /** The rectangle each keyed layer covers (213 × 120 around its centre). */
    private fun cells(): List<Region> = (0 until 6).map { i ->
        val cx = 640.0 / 3 * (i % 3) + 640.0 / 6
        val cy = 180.0 * (i / 3) + 90.0
        Region("c$i", Math.round(cx - 640.0 / 6).toInt(), Math.round(cy - 60.0).toInt(), 212, 120)
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
            // The cache shows every layer moving: each cell's barcode advances with k; a backward
            // step is a wrong (stale) frame shown from the cache and fails the test.
            val backward = (0 until 6).sumOf { i -> shown.mapNotNull { it.readings["c$i"] }.zipWithNext().count { (a, b) -> b < a } }
            val cellsMoving = (0 until 6).count { i ->
                val values = shown.mapNotNull { it.readings["c$i"] }
                values.size >= shown.size / 2 && values.zipWithNext().all { (a, b) -> b >= a } && values.last() > values.first()
            }
            val line = "6-layer chroma key, liveBudget 2 (emulator): live playback presented $liveShown/$frames, dropped $liveDropped, " +
                "stills fetched ${live.stillsFetched}; render ${RenderedFile(file)} in $ms ms; cached playback presented ${shown.size}/$frames, " +
                "dropped $dropped (%.1f%%), range frames $rangeFrames, cells moving $cellsMoving/6 (backward steps $backward), composite ${Timings(cached.compositeMs)}".format(dropPct)
            log18(line)
            assertTrue("live ended", liveEnded)
            assertTrue("live playback used stills for the over-budget layers: $line", live.stillsFetched > 0)
            assertTrue("cached ended", cachedEnded)
            // How many frames the cache presents is a GPU-speed number: the software GPU of the CI
            // emulator showed 8/120. DV_PERF_STRICT=1 needs 10 presented frames and the drop budget;
            // without it 3 frames keep the moving and backward-step checks below non-vacuous.
            val minShown = PerfGate.atLeast(10, 3)
            assertTrue("the cache played the range (>= $minShown frames, ${PerfGate.mode}): $line", rangeFrames >= shown.size - 1 && shown.size >= minShown)
            // The ≤ 2% drop budget is a device number (QA-04); with DV_PERF_STRICT=1 the cache must
            // meet it or beat live playback.
            if (PerfGate.strict) {
                assertTrue("<= 2% dropped from the cache, or fewer drops than live playback: $line", dropPct <= 2.0 || dropped < liveDropped)
            }
            assertEquals("no backward step (wrong frame) in the cached playback: $line", 0, backward)
            assertEquals("every layer moves in the cached playback: $line", 6, cellsMoving)
        }
    }
}
