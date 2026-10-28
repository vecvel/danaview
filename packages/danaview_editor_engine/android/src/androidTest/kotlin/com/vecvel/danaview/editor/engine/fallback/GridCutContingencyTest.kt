// OWNER: AND-16
//
// AND-16 on AND-01's grid-cut composition (3 slots, 6 layers, cuts at k ≡ 1, 2 mod 3, gaps), the
// case CompositionPlayer 1.11.1 cannot play (R1): every presented frame is identified by its pts
// (P(k), D-35) and checked layer by layer against the rule frame (ARCH §11.5) through the barcodes
// of ENG-05's counters. Playback at 24/30/60 fps (frames are dropped under load, never shown wrong;
// gating follows the plan), exact seek 200/200 plus every frame around every cut at 24/30/60 fps,
// and a scrub followed by exact seeks. Emulator numbers, logged under AND16.

package com.vecvel.danaview.editor.engine.fallback

import android.util.Log
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.support.PerfGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class GridCutContingencyTest {
    private val seqs = listOf(0, 1, 2)

    /** Every slot decodes live (the over-budget stills are OverBudgetStillsTest's). */
    private fun allLive() = ContingencyPreviewBackend.Config(liveBudget = 6)

    /** Mismatches of [f] against the plan (empty = every quadrant shows its rule frame or the background). */
    private fun mismatches(plan: RenderPlan, f: SinkFrame, pts: LongArray): List<String> {
        val out = ArrayList<String>()
        for (q in seqs) {
            val want = FallbackPlans.expectedIn(plan, q, f.k, pts)
            val got = f.readings["s$q"]
            if (want != got) out += "k=${f.k} s$q want=$want got=$got"
        }
        return out
    }

    private fun edges(plan: RenderPlan): Set<Long> {
        val g = com.vecvel.danaview.editor.engine.plan.FrameGrid.of(plan.canvas.fps)
        val d = g.frameIndexOf(plan.durUs)
        return plan.layers.filter { it.kind == PlanLayerKind.MEDIA }.flatMap { listOf(g.frameIndexOf(it.t0), g.frameIndexOf(it.t1)) }.filter { it in 1 until d }.toSortedSet()
    }

    @Test
    fun gridCutPlaybackShowsOnlyRuleFramesAt24_30_60() {
        val report = StringBuilder()
        var verified = 0
        var expectedTotal = 0
        for (fps in listOf(24, 30, 60)) {
            val plan = FallbackPlans.gridCut(fps)
            BackendHarness("and16_gridplay_$fps", plan, FallbackPlans.QUADRANTS.take(3), allLive()).use { h ->
                val pts = FallbackPlans.pts(h.engine.ctx, fps)
                assertTrue("warm-up seek", h.seekExact(0, 30_000) >= 0)
                h.sink.awaitK(0)
                Thread.sleep(100)
                h.sink.clear()
                h.host.dropped.clear()
                val frames = (plan.durUs / 1000)
                val ended = h.playToEnd(0, frames + 30_000)
                Thread.sleep(200)
                val shown = h.sink.frames.toList()
                val bad = shown.flatMap { mismatches(plan, it, pts) }
                val ks = shown.map { it.k }.toSet()
                val e = edges(plan)
                val bothSides = e.count { (it - 1) in ks && it in ks }
                val stats = h.stats()
                val line = "grid-cut playback $fps fps (emulator): presented ${ks.size}/${fps * 4}, dropped ${h.host.dropped.size}, " +
                    "held ${stats.held}, missed ${stats.missed}, rebuffers ${stats.rebuffers}, cuts seen on both sides $bothSides/${e.size}, " +
                    "composite ${Timings(stats.compositeMs)}, mismatches ${bad.size} ${bad.take(6)}"
                Log.i(AND16_TAG, line)
                report.appendLine(line)
                assertTrue("playback ended at $fps fps: $line", ended)
                assertEquals("no wrong frame at $fps fps: $line", emptyList<String>(), bad)
                assertTrue("presented frames are increasing", shown.zipWithNext().all { (a, b) -> b.k > a.k })
                verified += ks.size
                expectedTotal += fps * 4
            }
        }
        Log.i(AND16_TAG, report.toString())
        // Non-vacuous: frames were composited and verified at every rate (each one above checked
        // with no wrong frame). With DV_PERF_STRICT=1 (a quiet machine) at least a third of the
        // frames must be presented; a loaded CI emulator drops more (frames are dropped under
        // load, never shown wrong), so there an eighth suffices.
        val share = if (PerfGate.strict) 3 else 8
        assertTrue("verified $verified of $expectedTotal frames (need 1/$share):\n$report", verified * share >= expectedTotal)
    }

    @Test
    fun exactSeek200OfRandomFramesAndEveryFrameAroundTheCuts() {
        val rnd = Random(20261015)
        val report = StringBuilder()
        for (fps in listOf(24, 30, 60)) {
            val plan = FallbackPlans.gridCut(fps)
            BackendHarness("and16_gridseek_$fps", plan, FallbackPlans.QUADRANTS.take(3), allLive()).use { h ->
                val pts = FallbackPlans.pts(h.engine.ctx, fps)
                val d = (fps * 4).toLong()
                assertTrue("warm-up", h.seekExact(d / 2, 30_000) >= 0)
                val targets = ArrayList<Long>()
                for (e in edges(plan)) targets += listOf(e - 1, e)
                if (fps == 30) repeat(200) { targets += rnd.nextLong(0, d) }
                val latencies = ArrayList<Double>()
                val failures = ArrayList<String>()
                var ok = 0
                for (k in targets) {
                    val ms = h.seekExact(k)
                    if (ms < 0) {
                        failures += "k=$k timeout"
                        continue
                    }
                    latencies += ms
                    val f = h.sink.awaitK(k)
                    val mm = mismatches(plan, f, pts)
                    if (mm.isEmpty()) ok++ else failures += mm
                }
                val line = "exact seek $fps fps (emulator, 3 slots 640x360 from ${if (fps == 30) "1080p" else "720p"}): $ok/${targets.size} exact, ${Timings(latencies)}"
                Log.i(AND16_TAG, line)
                report.appendLine(line)
                assertEquals("$line\n${failures.take(10)}", targets.size, ok)
            }
        }
        Log.i(AND16_TAG, report.toString())
    }

    @Test
    fun scrubThenExactSeeksShowOnlyRuleFrames() {
        val plan = FallbackPlans.gridCut(30)
        BackendHarness("and16_scrub", plan, FallbackPlans.QUADRANTS.take(3), allLive()).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, 30)
            assertTrue(h.seekExact(60, 30_000) >= 0)
            h.sink.awaitK(60)
            Thread.sleep(100)
            h.sink.clear()
            // A drag over off-grid positions (47 ms steps, one every 120 ms; a cold 1080p deck seek
            // takes 0.3–1.8 s on the emulator): scrubs, one in flight, latest wins.
            var posMs = 0L
            val g = h.grid
            val t0 = System.nanoTime()
            while (posMs < plan.durUs / 1000 - 100) {
                h.seekAsync(g.frameIndexNearest(posMs * 1000), exact = false)
                Thread.sleep(120)
                posMs += 47
            }
            for (k in listOf(38L, 64L, 7L)) {
                assertTrue("post-scrub seek $k", h.seekExact(k) >= 0)
                h.sink.awaitK(k)
            }
            val scrubMs = (System.nanoTime() - t0) / 1e6
            val frames = h.sink.frames.toList()
            val bad = frames.flatMap { mismatches(plan, it, pts) }
            val offGrid = frames.count { kotlin.math.abs(it.ptsUs - g.platformTimeOfFrame(it.k)) > 1 }
            Log.i(AND16_TAG, "scrub (emulator): ${frames.size} frames presented in %.0f ms, %d wrong, %d off-grid pts".format(scrubMs, bad.size, offGrid))
            assertTrue("frames while scrubbing (${frames.size - 3} scrub frames)", frames.size > 3 + 2)
            assertEquals(0, offGrid)
            assertEquals(emptyList<String>(), bad)
            assertEquals(7L, frames.last().k)
        }
    }
}
