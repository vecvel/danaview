@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// LayerPlaceEffect (ARCH §13.3 "GL effects", "Compositing"; dv_place.glsl): the last effect of
// every visual item. Outputs a canvas-render-size STRAIGHT-alpha texture: the layer raster (or the
// solid colour) placed with the inverse §11.6 matrix, with sharpen, vignette, item mask, opacity,
// canvas masks and 1 px antialiased edges; DefaultVideoCompositor only blends it. A gated frame (gap
// items always) is one clear, no sampling.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind

/** The place effect of one visual item (file header). */
class LayerPlaceEffect(
    val binding: LayerBinding,
    val geometry: RenderGeometry,
    val options: LayerFrameOptions = LayerFrameOptions(),
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(context, this)

    private class Program(context: Context, private val e: LayerPlaceEffect) : BaseGlShaderProgram(false, 1) {
        private val programs = ShaderPrograms.acquire(context)
        private var inW = 1
        private var inH = 1

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            inW = inputWidth
            inH = inputHeight
            return Size(e.geometry.renderW, e.geometry.renderH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            programs.checkThread()
            val b = e.binding.resolve(presentationTimeUs)
            val place = b?.let { LayerFrames.place(it.params, e.geometry, programs.caps.maxTextureSize, e.options) }
            if (b == null || place == null || b.params.kind == PlanLayerKind.SPRITE) {
                programs.clearTransparent()
                return
            }
            programs.drawPlace(inputTexId, inW, inH, place, e.geometry.renderW, e.geometry.renderH, blend = false)
        }

        override fun release() {
            super.release()
            programs.release()
        }
    }
}
