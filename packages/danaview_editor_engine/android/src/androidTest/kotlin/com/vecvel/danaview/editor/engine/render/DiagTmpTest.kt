package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Test

class DiagTmpTest {
    @Test
    fun repeatability() {
        val fps = 30
        val plan = FallbackPlans.gridCut(fps)
        val q3 = FallbackPlans.QUADRANTS.take(3)
        RangeHarness("and18_diag", plan, q3).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            for (run in 0 until 6) {
                val (first, end) = 30L to 60L
                val file = h.rig.render(RangeCut.cut(plan, first, end), "diag_$run").first
                val rf = RenderedFile(file)
                val bm = rf.frames(0, (end - first).toInt())
                val bad = ArrayList<String>()
                bm.forEachIndexed { j, b ->
                    val k = first + j
                    for (q in 0 until 3) {
                        val got = FrameBarcode.decode(b, q3[q].barcode)
                        val want = FallbackPlans.expectedIn(plan, q, k, pts)
                        if (got != want) bad += "k=$k s$q $got/$want"
                    }
                }
                // Twice through MMR to rule out the retriever.
                val bm2 = rf.frames(0, (end - first).toInt())
                val mmrDiff = bm.indices.count { j -> (0 until 3).any { q -> FrameBarcode.decode(bm[j], q3[q].barcode) != FrameBarcode.decode(bm2[j], q3[q].barcode) } }
                log18("diag run $run sw=${h.rig.service.assetLoaderFactory != null}: wrong ${bad.size} $bad mmrDiff=$mmrDiff")
                if (run == 2) h.rig.service.assetLoaderFactory = null
            }
        }
    }
}
