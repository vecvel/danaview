@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// LayerPlaceEffect (ARCH §13.3 "GL effects", "Compositing"; dv_place.glsl): the last effect of
// every visual item. Outputs a canvas-render-size STRAIGHT-alpha texture; DefaultVideoCompositor
// only blends it. For a picture layer, in the API-03 reference renderer's order, on the top-left
// footprint raster LayerLookEffect drew (EffectPasses):
//   1. detail (dv_place DV_DETAIL): sharpen, vignette and item mask on the raster's texels, into an
//      internal scratch target that grows to the largest raster seen;
//   2. place: bilinear placement with the inverse §11.6 matrix, opacity, canvas masks and 1 px
//      antialiased edges.
// Solids are step 2 with the plan colour. A gated frame (gap items always) is one clear, no
// sampling.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/** The place effect of one visual item (file header). */
class LayerPlaceEffect(
    val binding: LayerBinding,
    val geometry: RenderGeometry,
    val options: LayerFrameOptions = LayerFrameOptions(),
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(context, this)

    private class Program(context: Context, private val e: LayerPlaceEffect) : BaseGlShaderProgram(false, 1) {
        private val programs = ShaderPrograms.acquire(context)
        private val detail = ScratchTarget()
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
            val bound = e.binding.resolve(presentationTimeUs)
            EffectPasses.place(programs, bound, e.geometry, e.options, inputTexId, inW, inH, detail)
            DiagTmpDump.dir?.let { dir ->
                val w = e.geometry.renderW
                val h = e.geometry.renderH
                val buf = java.nio.ByteBuffer.allocateDirect(w * h * 4)
                android.opengl.GLES20.glReadPixels(0, 0, w, h, android.opengl.GLES20.GL_RGBA, android.opengl.GLES20.GL_UNSIGNED_BYTE, buf)
                val bytes = ByteArray(w * h * 4)
                buf.get(bytes)
                val id = bound?.layer?.id?.replace('#', '_') ?: "none"
                java.io.File(dir, "${DiagTmpDump.tag}_${id}_${presentationTimeUs}_${DiagTmpDump.seq.incrementAndGet()}_${w}x$h.rgba").writeBytes(bytes)
            }
        }

        override fun release() {
            super.release()
            detail.release()
            programs.release()
        }
    }
}
