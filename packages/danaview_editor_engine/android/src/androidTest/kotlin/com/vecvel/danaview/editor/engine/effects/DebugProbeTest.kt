package com.vecvel.danaview.editor.engine.effects

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanReader
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DebugProbeTest {
    @Test
    fun wipeRow44() {
        val env = GlTestEnv()
        env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            val renderer = LayerRenderer(programs)
            val plan = PlanReader.readPlan(TestFixtures.open(FixtureTree.ENGINE_API, "images/plans/transition_wipe.json").use { it.readBytes() })
            val layer = plan.layers.first { it.id == "it_right0000001#v" }
            val p0 = ParamSnapshot.evaluate(layer, plan, 2166667)
            val img = PngDecoder.decode(TestFixtures.open(FixtureTree.ENGINE_API, "images/sources/frame_counter_720p25_1280x720_f00017.png").use { it.readBytes() })
            val src = GlTestEnv.uploadRgba8(img.toRgba8(), img.width, img.height)
            val g = RenderGeometry(1920, 1080, 96, 54)
            for (variant in listOf("asis", "nocmask", "noaa")) {
                val p = if (variant == "nocmask") p0.copy(cmasks = emptyList()) else p0
                val opts = if (variant == "noaa") LayerFrameOptions(antialias = false) else LayerFrameOptions()
                val f = LayerFrames.frame(p, g, 4096, img.width, img.height, options = opts)!!
                Log.w("AND09.dbg", "$variant cmasks=${p.cmasks} place=${f.place.inverse} edge=${f.place.edgeScale} cm=${f.place.canvasMasks}")
                val t = GlTarget.rgba8(96, 54)
                t.bind()
                programs.clearOpaque(0xFF000000.toInt())
                renderer.draw(f, SourceTexture(src, img.width, img.height), null, null, t, 96, 54, blend = true)
                t.bind()
                val px = GlTestEnv.readRgba8(96, 54)
                for (y in listOf(42, 43, 44, 45)) Log.w("AND09.dbg", "$variant row $y: " + (14..24).joinToString { (px[(y * 96 + it) * 4].toInt() and 0xFF).toString() })
                t.release()
            }
            GlResources.deleteTexture(src)
            renderer.release()
            programs.release()
        }
        env.close()
    }
}
