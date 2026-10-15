// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.render

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.fallback.Region
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class DiagTmpProbe2Test {
    private val args = InstrumentationRegistry.getArguments()
    private val q3 = FallbackPlans.QUADRANTS.take(3)

    private fun edges(plan: RenderPlan): List<Long> {
        val g = FrameGrid.of(plan.canvas.fps)
        val d = g.frameIndexOf(plan.durUs)
        return plan.layers.flatMap { listOf(g.frameIndexOf(it.t0), g.frameIndexOf(it.t1)) }.filter { it in 1 until d }.toSortedSet().toList()
    }

    private fun mism(plan: RenderPlan, k: Long, readings: Map<String, Int?>, pts: LongArray): List<String> =
        (0 until 3).mapNotNull { q ->
            val want = FallbackPlans.expectedIn(plan, q, k, pts)
            val got = readings["s$q"]
            if (want != got) "k=$k s$q want=$want got=$got" else null
        }

    private fun fileCheck(plan: RenderPlan, file: File, first: Long, end: Long, pts: LongArray): List<String> {
        val bitmaps = RenderedFile(file).frames(0, (end - first).toInt())
        return bitmaps.withIndex().flatMap { (j, b) -> mism(plan, first + j, q3.associate { it.name to FrameBarcode.decode(b, it.barcode) }, pts) }
    }

    @Test
    fun probe() {
        val fps = args.getString("probeFps")?.toInt() ?: 24
        val reps = args.getString("probeReps")?.toInt() ?: 5
        val spin = args.getString("probeSpin")?.toInt() ?: 0
        val stop = AtomicBoolean(false)
        val spinners = (0 until spin).map { Thread { var x = 0L; while (!stop.get()) { x = x * 31 + 7 } }.apply { isDaemon = true; start() } }
        val outDir = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)!!
        var playBad = 0
        var fileBad = 0
        try {
            val plan = FallbackPlans.gridCut(fps)
            val frames = (fps * 8).toLong()
            val base = FallbackPlans.plan(fps, frames, listOf(FallbackPlans.mainLayer(fps, frames, offset = 0)))
            repeat(reps) { rep ->
                var lightF: File? = null
                RangeHarness("p2light_${fps}_$rep", base, emptyList()).use { lh -> lightF = lh.rig.render(RangeCut.cut(base, 0, frames), "p2light_${fps}_$rep").first }
                val asset = PlanAsset(PlanAssetKind.VIDEO, "file://" + lightF!!.absolutePath, fp = "p2light$fps-$rep", w = 640, h = 360)
                val lightPlan = plan.copy(assets = mapOf("counter" to asset))
                RangeHarness("p2_${fps}_$rep", lightPlan, q3).use { h ->
                    val table = SourceFrameIndex(h.engine.ctx.appContext).frameTimes(asset.uri)
                    val e = edges(lightPlan)
                    val rs = listOf(e[0] to e[2], e[3] to e[5])
                    val files = rs.mapIndexed { i, (a, b) -> h.rig.render(RangeCut.cut(lightPlan, a, b), "p2_${rep}_$i").first }
                    val fb = rs.indices.flatMap { i -> fileCheck(lightPlan, files[i], rs[i].first, rs[i].second, table) }
                    if (fb.isNotEmpty()) fileBad++
                    h.bind(rs.mapIndexed { i, (a, b) -> h.rig.msg(a, b, h.grid, files[i]) })
                    h.sink.keepAll = true
                    h.seekExact(0, 30_000)
                    h.sink.awaitK(0)
                    Thread.sleep(200)
                    h.sink.clear()
                    h.playToEnd(0, 70_000)
                    Thread.sleep(200)
                    val runs = ArrayList<List<Shown>>()
                    runs += h.sink.frames.toList()
                    for (edge in rs.flatMap { listOf(it.first, it.second) }) {
                        h.seekExact(edge - 2)
                        h.sink.awaitK(edge - 2)
                        Thread.sleep(150)
                        h.sink.clear()
                        h.play(edge - 2)
                        val until = System.currentTimeMillis() + 2_000
                        while (System.currentTimeMillis() < until && h.sink.frames.none { it.k >= edge + 2 }) Thread.sleep(5)
                        h.pause()
                        Thread.sleep(100)
                        runs += h.sink.frames.toList()
                    }
                    val all = runs.flatten()
                    val bad = all.flatMap { f -> mism(lightPlan, f.k, f.readings, table).map { it to f } }
                    if (bad.isNotEmpty()) {
                        playBad++
                        for ((msg, f) in bad.distinctBy { it.second }.take(4)) {
                            val png = File(outDir, "p2_${fps}_${rep}_k${f.k}_${System.nanoTime()}.png")
                            f.rgba?.let { px -> png.outputStream().use { rgbaBitmap(px, 640, 360).compress(Bitmap.CompressFormat.PNG, 100, it) } }
                            val inRange = rs.indexOfFirst { (a, b) -> f.k in a until b }
                            val fileNow = if (inRange >= 0) fileCheck(lightPlan, files[inRange], rs[inRange].first, rs[inRange].second, table) else listOf("live frame")
                            log18("PROBE2 rep $rep PLAYBACK WRONG $msg readings=${f.readings} range=$inRange file-now=$fileNow png=${png.name}")
                        }
                    }
                    log18("PROBE2 rep $rep: presented ${all.size}, playback wrong ${bad.size} ${bad.take(4).map { it.first }}, file wrong ${fb.size} $fb, stats ${h.stats().rangeFrames} range frames, dropped ${h.host.dropped.size}")
                    if (fb.isEmpty() && bad.isEmpty()) files.forEach { it.delete() }
                }
            }
        } finally {
            stop.set(true)
            spinners.forEach { it.join(1000) }
            log18("PROBE2 SUMMARY fps=$fps reps=$reps spin=$spin playBad=$playBad fileBad=$fileBad")
        }
    }
}
