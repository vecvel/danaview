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
import android.opengl.GLES20
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
        private var raster: GlTarget? = null

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            return Size(e.geometry.renderW, e.geometry.renderH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        /** The internal target, grown to hold a [w] × [h] raster. */
        private fun target(w: Int, h: Int): GlTarget {
            val t = raster
            if (t != null && t.width >= w && t.height >= h) return t
            val nw = maxOf(w, t?.width ?: 0)
            val nh = maxOf(h, t?.height ?: 0)
            t?.release()
            return GlTarget.rgba8(nw, nh).also { raster = it }
        }

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
            val sprite = textures.sprite(asset)
            val p = frame.place
            val out = GlResources.currentFramebuffer()
            val viewport = GlResources.currentViewport()
            val t = target(p.refRasterW, p.refRasterH)
            t.bind()
            GLES20.glViewport(0, t.height - p.refRasterH, p.refRasterW, p.refRasterH)
            programs.drawSpriteRaster(sprite, p.refRasterW, p.refRasterH, t.height, p.revealShown)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out)
            GLES20.glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
            programs.drawPlace(t.texture, t.width, t.height, p, e.geometry.renderW, e.geometry.renderH, blend = false, rasterW = p.refRasterW, rasterH = p.refRasterH)
        }

        override fun release() {
            super.release()
            raster?.release()
            raster = null
            textures.release()
            programs.release()
        }
    }
}
