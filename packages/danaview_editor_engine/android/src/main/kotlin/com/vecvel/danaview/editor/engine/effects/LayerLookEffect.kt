@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// LayerLookEffect (ARCH §13.3 "GL effects", dv_look.glsl): the first effect of a media or image
// item. `configure` sizes the layer raster once: RasterSizing.MAX_SCALE = min(source crop,
// round(base·maxScale·renderScale)), so 4K sources are downscaled first without softening
// keyframed zooms; RasterSizing.SOURCE (look stills through FrameExtractor) keeps the crop at
// source resolution. drawFrame resolves the layer at the frame (LayerBinding, D-35); a gated frame
// is one clear. Output: premultiplied RGBA of the layer raster (crop, chroma + spill, grade, LUT;
// matte flag for the matte editing mode).

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/** The look effect of one layer item (file header). */
class LayerLookEffect(
    val binding: LayerBinding,
    /** Canvas and render size (MAX_SCALE sizing). */
    val geometry: RenderGeometry,
    val sizing: RasterSizing = RasterSizing.MAX_SCALE,
    val options: LayerFrameOptions = LayerFrameOptions(),
    /** Opens LUT assets; null = the context's ContentResolver. */
    val assets: EffectAssets? = null,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = Program(context, this)

    private class Program(context: Context, private val e: LayerLookEffect) : BaseGlShaderProgram(false, 1) {
        private val programs = ShaderPrograms.acquire(context)
        private val textures = GlAssetTextures(e.assets ?: EffectAssets.of(context.contentResolver), programs.caps)
        private var srcW = 0
        private var srcH = 0
        private var outW = 1
        private var outH = 1

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            programs.checkThread()
            srcW = inputWidth
            srcH = inputHeight
            val b = e.binding.current()
            val size = if (b == null) {
                Pair(inputWidth, inputHeight)
            } else {
                LayerFrames.rasterSize(
                    e.sizing,
                    b.params.base,
                    maxOf(e.binding.maxScale, kotlin.math.abs(b.params.xf.s)),
                    e.options.cropOverride ?: b.params.crop,
                    inputWidth,
                    inputHeight,
                    e.geometry,
                    programs.caps.maxTextureSize,
                )
            }
            outW = size.first
            outH = size.second
            return Size(outW, outH)
        }

        override fun shouldClearTextureBuffer(): Boolean = false

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            programs.checkThread()
            val b = e.binding.resolve(presentationTimeUs)
            if (b == null || (e.sizing != RasterSizing.SOURCE && LayerFrames.place(b.params, e.geometry, programs.caps.maxTextureSize, e.options) == null)) {
                programs.clearTransparent()
                return
            }
            val look = LayerFrames.look(b.params, srcW, srcH, outW, outH, e.options)
            val lut = look.lutAsset?.let { b.plan.assets[it] }?.let { textures.lut(it) }
            programs.drawLook(SourceTexture(inputTexId, srcW, srcH), look, lut)
        }

        override fun release() {
            super.release()
            textures.release()
            programs.release()
        }
    }
}
