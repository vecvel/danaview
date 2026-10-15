// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.render

import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.effects.DiagTmpDump
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

    /** Barcode of quadrant [q] in a dumped place output (GL rows bottom-up). */
    private fun dumpReading(f: File, q: Int): Int? {
        val m = Regex("_(\\d+)x(\\d+)\\.rgba$").find(f.name)!!
        val w = m.groupValues[1].toInt()
        val h = m.groupValues[2].toInt()
        val raw = f.readBytes()
        val flipped = ByteArray(raw.size)
        for (y in 0 until h) System.arraycopy(raw, (h - 1 - y) * w * 4, flipped, y * w * 4, w * 4)
        val up = FrameBarcode.decode(flipped, w, h, region = q3[q].barcode)
        val down = FrameBarcode.decode(raw, w, h, region = q3[q].barcode)
        return up ?: down?.let { -it }
    }

    @Test
    fun probe() {
        val fps = args.getString("probeFps")?.toInt() ?: 24
        val reps = args.getString("probeReps")?.toInt() ?: 5
        val spin = args.getString("probeSpin")?.toInt() ?: 0
        val dump = args.getString("probeDump") == "1"
        val stop = AtomicBoolean(false)
        val spinners = (0 until spin).map { Thread { var x = 0L; while (!stop.get()) { x = x * 31 + 7 } }.apply { isDaemon = true; start() } }
        var rangeBad = 0
        try {
            val plan = FallbackPlans.gridCut(fps)
            val frames = (fps * 8).toLong()
            val base = FallbackPlans.plan(fps, frames, listOf(FallbackPlans.mainLayer(fps, frames, offset = 0)))
            var lightF: File? = null
            RangeHarness("plight_$fps", base, emptyList()).use { lh -> lightF = lh.rig.render(RangeCut.cut(base, 0, frames), "plight_$fps").first }
            val light = lightF!!
            val asset = PlanAsset(PlanAssetKind.VIDEO, "file://" + light.absolutePath, fp = "plight$fps", w = 640, h = 360)
            val lightPlan = plan.copy(assets = mapOf("counter" to asset))
            RangeHarness("probe_$fps", lightPlan, q3).use { h ->
                val lpts = SourceFrameIndex(h.engine.ctx.appContext).frameTimes(asset.uri)
                val origPts = FallbackPlans.pts(h.engine.ctx, fps)
                val full = Region("m", 0, 0, 640, 360)
                val lb = RenderedFile(light).frames(0, frames.toInt()).withIndex().mapNotNull { (j, b) ->
                    val want = FallbackPlans.expected(base, base.layers[0], j.toLong(), origPts)
                    val got = FrameBarcode.decode(b, full.barcode)
                    if (want != got) "j=$j want=$want got=$got" else null
                }
                log18("PROBE light: wrong ${lb.size} ${lb.take(8)}")
                val e = edges(lightPlan)
                val dumpRoot = File(h.engine.ctx.appContext.cacheDir, "diagdump").apply { deleteRecursively(); mkdirs() }
                repeat(reps) { rep ->
                    val whole = args.getString("probeWhole") == "1"
                    val sw = args.getString("probeHw") != "1"
                    h.rig.service.assetLoaderFactory = if (sw) ({ com.vecvel.danaview.editor.engine.composition.ExportRunner.softwareFirstAssetLoader() }) else null
                    val d = FrameGrid.of(fps).frameIndexOf(lightPlan.durUs)
                    val rlist = if (whole) listOf(0L to d) else listOf(e[0] to e[2], e[3] to e[5])
                    for ((i, r) in rlist.withIndex()) {
                        val dd = File(dumpRoot, "r${rep}_$i").apply { mkdirs() }
                        if (dump) DiagTmpDump.dir = dd
                        androidx.media3.effect.DebugTraceUtil.enableTracing = true
                        androidx.media3.effect.DebugTraceUtil.reset()
                        val f = try {
                            h.rig.render(RangeCut.cut(lightPlan, r.first, r.second), "prange_${fps}_${rep}_$i").first
                        } finally {
                            DiagTmpDump.dir = null
                        }
                        val bad = checkRange(lightPlan, f, r.first, r.second, lpts)
                        if (bad.isNotEmpty()) {
                            rangeBad++
                            val again = checkRange(lightPlan, f, r.first, r.second, lpts)
                            log18("PROBE rep $rep range $r: wrong ${bad.size} $bad; second decode ${again.size} $again")
                            androidx.media3.effect.DebugTraceUtil.generateTraceSummary().chunked(3000).forEach { log18("PTRACE $it") }
                            // The place outputs of every layer: pts → barcode in its quadrant.
                            for (l in lightPlan.layers) {
                                val q = l.seq ?: continue
                                val dumps = dd.listFiles().orEmpty().filter { it.name.contains("_${l.id.replace('#', '_')}_") }
                                    .sortedBy { it.name.split('_').let { p -> p[p.size - 2].toInt() } }
                                if (dumps.isEmpty()) continue
                                log18("PROBE   layer ${l.id} q$q: " + dumps.joinToString { d ->
                                    val p = d.name.split('_')
                                    "${p[p.size - 3]}#${p[p.size - 2]}=${dumpReading(d, q)}"
                                })
                            }
                        } else {
                            log18("PROBE rep $rep range $r: ok")
                            if (rep == 0 && i == 0) for (l in lightPlan.layers) {
                                val q = l.seq ?: continue
                                val dumps = dd.listFiles().orEmpty().filter { it.name.contains("_${l.id.replace('#', '_')}_") }
                                    .sortedBy { it.name.split('_').let { p -> p[p.size - 2].toInt() } }
                                if (dumps.isEmpty()) continue
                                log18("PROBE   ok-layer ${l.id} q$q: " + dumps.joinToString { d ->
                                    val p = d.name.split('_')
                                    "${p[p.size - 3]}#${p[p.size - 2]}=${dumpReading(d, q)}"
                                })
                            }
                            f.delete()
                        }
                        dd.deleteRecursively()
                    }
                }
                log18("PROBE SUMMARY fps=$fps reps=$reps spin=$spin dump=$dump rangeBad=$rangeBad")
            }
        } finally {
            stop.set(true)
            spinners.forEach { it.join(1000) }
        }
    }
}
