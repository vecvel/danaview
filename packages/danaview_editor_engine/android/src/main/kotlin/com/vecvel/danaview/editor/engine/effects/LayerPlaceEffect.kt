@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// LayerPlaceEffect (ARCH §13.3 "GL effects", "Compositing"; dv_place.glsl): the last effect of
// every visual item. Outputs a canvas-render-size STRAIGHT-alpha texture; DefaultVideoCompositor
// only blends it. For a picture layer, in the API-03 reference renderer's order:
//   1. resample: when the incoming raster (LayerLookEffect sized it for the layer's largest
//      animated scale) is larger than this frame's reference raster round(base·|s|·renderScale), it
//      is box-resampled down to it (so a keyframed zoom stays sharp at its peak and is filtered
//      like the reference below it);
//   2. detail (dv_place DV_DETAIL): sharpen, vignette and item mask on the raster's texels;
//   3. place: bilinear placement with the inverse §11.6 matrix, opacity, canvas masks and 1 px
//      antialiased edges.
// Steps 1–2 draw into the top-left of two internal scratch targets that grow to the largest raster
// seen. Solids are step 3 with the plan colour. A gated frame (gap items always) is one clear, no
// sampling.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import android.opengl.GLES20
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
        private val scratch = arrayOfNulls<GlTarget>(2)
        private var inW = 1
        private var inH = 1

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            inW = inputWidth
            inH = inputHeight
            return Size(e.geometry.renderW, e.geometry.renderH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        /** Scratch target [slot], grown to hold a [w] × [h] raster, bound with its top-left [w] × [h] viewport. */
        private fun bindScratch(slot: Int, w: Int, h: Int): GlTarget {
            var t = scratch[slot]
            if (t == null || t.width < w || t.height < h) {
                val nw = maxOf(w, t?.width ?: 0)
                val nh = maxOf(h, t?.height ?: 0)
                t?.release()
                t = GlTarget.rgba8(nw, nh)
                scratch[slot] = t
            }
            t.bind()
            GLES20.glViewport(0, t.height - h, w, h)
            return t
        }

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            programs.checkThread()
            val b = e.binding.resolve(presentationTimeUs)
            val place = b?.let { LayerFrames.place(it.params, e.geometry, programs.caps.maxTextureSize, e.options) }
            if (b == null || place == null || b.params.kind == PlanLayerKind.SPRITE) {
                programs.clearTransparent()
                return
            }
            if (place.solid != null) {
                programs.drawPlace(0, 1, 1, place, e.geometry.renderW, e.geometry.renderH, blend = false)
                return
            }
            val out = GlResources.currentFramebuffer()
            val viewport = GlResources.currentViewport()
            var tex = inputTexId
            var texW = inW
            var texH = inH
            var rw = inW
            var rh = inH
            if (place.needsResample(rw, rh)) {
                val t = bindScratch(0, place.refRasterW, place.refRasterH)
                programs.drawResample(tex, texW, texH, place.refRasterW, place.refRasterH, t.height)
                tex = t.texture
                texW = t.width
                texH = t.height
                rw = place.refRasterW
                rh = place.refRasterH
            }
            if (place.needsDetail) {
                val t = bindScratch(1, rw, rh)
                programs.drawDetail(tex, texW, texH, rw, rh, place, t.height)
                tex = t.texture
                texW = t.width
                texH = t.height
            }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out)
            GLES20.glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
            programs.drawPlace(tex, texW, texH, place, e.geometry.renderW, e.geometry.renderH, blend = false, rasterW = rw, rasterH = rh)
        }

        override fun release() {
            super.release()
            for (i in scratch.indices) {
                scratch[i]?.release()
                scratch[i] = null
            }
            programs.release()
        }
    }
}
