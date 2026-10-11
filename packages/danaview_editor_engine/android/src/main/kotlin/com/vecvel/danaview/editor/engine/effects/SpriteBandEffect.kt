@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// SpriteBandEffect (ARCH §13.3, §11.6 "Sprite"; export only): draws the sprite layer active in its
// sequence at each frame (a band of cues or one text item) onto a canvas-render-size STRAIGHT-alpha
// texture: the `.vsprite` texture (reduced to GL_MAX_TEXTURE_SIZE) placed with M, sampled over
// each reference raster texel's footprint (≤ 8×8 taps, so an 8× sprite stays sharp up to 8× scale
// and is box-filtered below), with the reveal map (a texel is drawn iff glyph < floor(reveal)),
// opacity, canvas masks and antialiased edges. The item's own input (a transparent canvas image)
// is ignored. A frame without an active sprite is one clear.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind

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

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            return Size(e.geometry.renderW, e.geometry.renderH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            programs.checkThread()
            val b = e.binding.resolve(presentationTimeUs)
            val asset = b?.layer?.asset?.let { b.plan.assets[it] }
            val frame = if (b == null || asset == null || asset.kind != PlanAssetKind.SPRITE || b.params.kind != PlanLayerKind.SPRITE) {
                null
            } else {
                LayerFrames.frame(b.params, e.geometry, programs.caps.maxTextureSize, reveal = asset.reveal == true)
            }
            if (frame == null || asset == null) {
                programs.clearTransparent()
                return
            }
            programs.drawSprite(textures.sprite(asset), frame.place, e.geometry.renderW, e.geometry.renderH, blend = false)
        }

        override fun release() {
            super.release()
            textures.release()
            programs.release()
        }
    }
}
