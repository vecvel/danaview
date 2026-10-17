@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// SpriteBandEffect (ARCH §13.3, §11.6 "Sprite"; export only): draws the sprite layer active in its
// sequence at each frame (a band of cues or one text item) onto a canvas-render-size STRAIGHT-alpha
// texture, in the reference renderer's two steps: (1) the `.vsprite` texture (reduced to
// GL_MAX_TEXTURE_SIZE) is resampled onto the layer raster at round(base·|s|·renderScale) px, each
// texel the average of ≤ 8 × 8 taps over its sprite footprint with the reveal map applied per tap (a
// tap is kept iff glyph < floor(reveal)), so an 8× sprite stays sharp up to 8× scale and is
// box-filtered below; (2) the raster is placed with M like any layer (opacity, canvas masks,
// antialiased edges). The raster lives in the top-left corner of one internal target that grows
// to the largest raster seen, so an animated scale does not reallocate every frame. The item's own
// input (a transparent canvas image) is ignored. A frame without an active sprite is one clear.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/** The sprite effect of one sprite item or band (file header). */
class SpriteBandEffect(
    val binding: LayerBinding,
    val geometry: RenderGeometry,
    /** Opens `.vsprite` assets; null = the context's ContentResolver. */
    val assets: EffectAssets? = null,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(context, this)

    private class Program(context: Context, private val e: SpriteBandEffect) : BaseGlShaderProgram(false, 1) {
        private val programs = ShaderPrograms.acquire(context)
        private val textures = GlAssetTextures(e.assets ?: EffectAssets.of(context.contentResolver), programs.caps)
        private val raster = ScratchTarget()

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            return Size(e.geometry.renderW, e.geometry.renderH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            EffectPasses.sprite(programs, e.binding.resolve(presentationTimeUs), e.geometry, textures::sprite, raster)
        }

        override fun release() {
            super.release()
            raster.release()
            textures.release()
            programs.release()
        }
    }
}
