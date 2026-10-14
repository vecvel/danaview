package com.vecvel.danaview.editor.engine.paused

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanDetail
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLut
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DiagTmpTest {
    @Test
    fun firstRenderCost() {
        val steps = listOf(
            "plain" to PlanEffects.NONE,
            "adj" to PlanEffects(adj = PlanAdjust(contrast = 0.1)),
            "sharpen" to PlanEffects(detail = PlanDetail(sharpen = 0.3)),
            "blur" to PlanEffects(detail = PlanDetail(blur = 0.1)),
            "lut" to PlanEffects(lut = PlanLut("lut", 0.7)),
        )
        val plan0 = PausedPlans.plan(listOf(PausedPlans.media("main#v", 10, 0, 0, PausedPlans.FRAMES, 10)))
        PausedHarness("and17_diag", plan0).use { h ->
            await<Unit> { h.renderer.warmUp(it) }
            h.prefetch(3)
            for ((i, s) in steps.withIndex()) {
                h.setPlan(PausedPlans.plan(listOf(PausedPlans.media("main#v", 10, 0, 0, PausedPlans.FRAMES, 10, fx = s.second)), rev = 2L + i))
                val a = h.render()
                val b = h.render()
                Log.i(AND17_TAG, "diag ${s.first}: first GL ${a.glMs} fetch ${a.fetchMs}, second GL ${b.glMs}")
            }
        }
    }
}
