// OWNER: AND-18
// TEMPORARY diagnostic (fixer round): where do stale input frames come from? Not a test of record.

package com.vecvel.danaview.editor.engine.render

import android.util.Log
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.common.C
import com.vecvel.danaview.editor.engine.composition.ExportRunner
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Test
import java.io.File

@androidx.annotation.OptIn(UnstableApi::class)
class StaleInputProbeTest {
    private val tag = "DVPROBE"

    @Test
    fun probe() {
        val runs = (androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("probeRuns") ?: "5").toInt()
        val mode = androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("probeMode") ?: "single,render"
        val uri = FallbackPlans.uri(FallbackPlans.counterName(24))
        val dir = File(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "probe").apply { mkdirs() }
        if ("single" in mode) {
            for (sw in listOf(true, false)) {
                for (r in 0 until runs) {
                    val out = File(dir, "single_${sw}_$r.mp4")
                    val item = EditedMediaItem.Builder(MediaItem.fromUri(uri.toUri())).setRemoveAudio(true).build()
                    val comp = Composition.Builder(EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO)).addItem(item).build()).build()
                    val (res, ms) = ExportRunner.export(comp, out, softwareDecoders = sw)
                    val rf = RenderedFile(out)
                    val n = rf.samples
                    val a = rf.frames(0, n).map { FrameBarcode.decode(it) }
                    val b = rf.frames(0, n).map { FrameBarcode.decode(it) }
                    val wrong = a.withIndex().filter { (j, v) -> v != j }.map { "j=${it.index} got=${it.value}" }
                    Log.i(tag, "single sw=$sw run $r: ${res.videoFrameCount} frames in $ms ms; wrong ${wrong.size} ${wrong.take(8)}; second decode differs at ${a.indices.filter { a[it] != b[it] }.take(8)}")
                }
            }
        }
        if ("render" in mode) {
            val fps = 30
            val plan = FallbackPlans.gridCut(fps)
            val q3 = FallbackPlans.QUADRANTS.take(3)
            val first = 31L
            val end = 92L
            val n = (end - first).toInt()
            for (sw in listOf(true, false)) {
                RangeHarness("probe_render_$sw", plan, q3).use { h ->
                    val pts = FallbackPlans.pts(h.engine.ctx, fps)
                    val rig = RenderRig(h.engine, softwareDecoders = sw)
                    for (r in 0 until runs) {
                        val (file, ms) = rig.render(RangeCut.cut(plan, first, end), "probe_${sw}_$r")
                        fun read(): List<String> {
                            val out = ArrayList<String>()
                            for ((j, bmp) in RenderedFile(file).frames(0, n).withIndex()) {
                                val k = first + j
                                for (q in 0 until 3) {
                                    val want = FallbackPlans.expectedIn(plan, q, k, pts)
                                    val got = FrameBarcode.decode(bmp, q3[q].barcode)
                                    if (want != got) out += "k=$k s$q want=$want got=$got"
                                }
                            }
                            return out
                        }
                        val w1 = read()
                        val w2 = read()
                        Log.i(tag, "render sw=$sw run $r in $ms ms: wrong ${w1.size} ${w1.take(8)}; second decode same=${w1 == w2}")
                    }
                }
            }
        }
    }
}
