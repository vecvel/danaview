@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// SeparableBlurEffect (ARCH §11.6 "Blur", §13.3 "GL effects"): added only to items whose layer
// blurs at some time (static or animated detail.blur > 0, AND-08 `needsBlur`). Per frame
// σ = blur·0.03·min(W, H) plan-canvas px is converted to the look raster's px through the layer's
// current scale and the render scale (LayerFrames.blur); below 0.5 reference px the frame is
// copied unchanged. It works on the top-left footprint raster LayerLookEffect drew
// (EffectPasses): horizontal pass into an internal RGBA8 target, vertical pass into Media3's output
// (premultiplied in and out). A gated frame is one clear.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/** The blur effect of one layer item (file header). */
class SeparableBlurEffect(
    val binding: LayerBinding,
    val geometry: RenderGeometry,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(context, this)

    private class Program(context: Context, private val e: SeparableBlurEffect) : BaseGlShaderProgram(false, 1) {
        private val programs = ShaderPrograms.acquire(context)
        private var w = 1
        private var h = 1
        private val tmp = ScratchTarget()

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            w = inputWidth
            h = inputHeight
            return Size(w, h)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            EffectPasses.blur(programs, e.binding.resolve(presentationTimeUs), e.geometry, inputTexId, w, h, tmp)
        }

        override fun release() {
            super.release()
            tmp.release()
            programs.release()
        }
    }
}
