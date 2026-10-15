// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.render

import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.fallback.Region
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Test
import java.io.File

class DiagTmpProbeTest {
    private val args = InstrumentationRegistry.getArguments()
    private val q3 = FallbackPlans.QUADRANTS.take(3)

    private fun edges(plan: RenderPlan): List<Long> {
        val g = FrameGrid.of(plan.canvas.fps)
        val d = g.frameIndexOf(plan.durUs)
        return plan.layers.flatMap { listOf(g.frameIndexOf(it.t0), g.frameIndexOf(it.t1)) }.filter { it in 1 until d }.toSortedSet().toList()
    }

    private fun checkRange(plan: RenderPlan, file: File, first: Long, end: Long, pts: LongArray): List<String> {
        val n = (end - first).toInt()
        val bitmaps = RenderedFile(file).frames(0, n)
        val out = ArrayList<String>()
        for ((j, b) in bitmaps.withIndex()) {
            val k = first + j
            for (q in 0 until 3) {
                val want = FallbackPlans.expectedIn(plan, q, k, pts)
                val got = FrameBarcode.decode(b, q3[q].barcode)
                if (want != got) out += "k=$k s$q want=$want got=$got"
            }
        }
        return out
    }

    @Test
    fun probe() {
        val fps = args.getString("probeFps")?.toInt() ?: 24
        val reps = args.getString("probeReps")?.toInt() ?: 5
        val spin = args.getString("probeSpin")?.toInt() ?: 0
        val stop = java.util.concurrent.atomic.AtomicBoolean(false)
        val spinners = (0 until spin).map { Thread { var x = 0L; while (!stop.get()) { x = x * 31 + 7 } }.apply { isDaemon = true; start() } }
        try {
            val plan = FallbackPlans.gridCut(fps)
            val frames = (fps * 8).toLong()
            val base = FallbackPlans.plan(fps, frames, listOf(FallbackPlans.mainLayer(fps, frames, offset = 0)))
            RangeHarness("probe_$fps", plan, q3).use { h ->
                val origPts = FallbackPlans.pts(h.engine.ctx, fps)
                val full = Region("m", 0, 0, 640, 360)
                val playLoad = args.getString("probePlay") == "1"
                val player = if (!playLoad) null else Thread {
                    try {
                        h.seekExact(0, 30_000)
                        while (!stop.get()) h.playToEnd(0, 60_000)
                    } catch (t: Throwable) {
                        log18("PROBE player stopped: $t")
                    }
                }.apply { isDaemon = true; start() }
                var lightBad = 0
                var rangeBad = 0
                repeat(reps) { rep ->
                    var lightF: File? = null
                    RangeHarness("plight_${fps}_$rep", base, emptyList()).use { lh -> lightF = lh.rig.render(RangeCut.cut(base, 0, frames), "plight_${fps}_$rep").first }
                    val light = lightF!!
                    val lb = RenderedFile(light).frames(0, frames.toInt()).withIndex().mapNotNull { (j, b) ->
                        val want = FallbackPlans.expected(base, base.layers[0], j.toLong(), origPts)
                        val got = FrameBarcode.decode(b, full.barcode)
                        if (want != got) "j=$j want=$want got=$got" else null
                    }
                    if (lb.isNotEmpty()) lightBad++
                    log18("PROBE rep $rep light: wrong ${lb.size} ${lb.take(8)}")
                    val asset = PlanAsset(PlanAssetKind.VIDEO, "file://" + light.absolutePath, fp = "plight$fps-$rep", w = 640, h = 360)
                    val lightPlan = plan.copy(assets = mapOf("counter" to asset))
                    val lpts = SourceFrameIndex(h.engine.ctx.appContext).frameTimes(asset.uri)
                    val e = edges(lightPlan)
                    for ((i, r) in listOf(e[0] to e[2], e[3] to e[5]).withIndex()) {
                        val f = h.rig.render(RangeCut.cut(lightPlan, r.first, r.second), "prange_${fps}_${rep}_$i").first
                        val bad = checkRange(lightPlan, f, r.first, r.second, lpts)
                        if (bad.isNotEmpty()) {
                            rangeBad++
                            val again = checkRange(lightPlan, f, r.first, r.second, lpts)
                            log18("PROBE rep $rep range $r: wrong ${bad.size} $bad; second decode ${again.size} $again")
                        } else {
                            log18("PROBE rep $rep range $r: ok")
                            f.delete()
                        }
                    }
                    if (lb.isEmpty()) light.delete()
                }
                stop.set(true)
                player?.join(70_000)
                log18("PROBE SUMMARY fps=$fps reps=$reps spin=$spin play=$playLoad lightBad=$lightBad rangeBad=$rangeBad")
            }
        } finally {
            stop.set(true)
            spinners.forEach { it.join(1000) }
        }
    }
}
