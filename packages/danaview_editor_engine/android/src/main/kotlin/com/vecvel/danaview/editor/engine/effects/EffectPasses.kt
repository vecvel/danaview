// OWNER: AND-09
//
// The per-frame GL work of the Media3 effect programs (LayerLookEffect, SeparableBlurEffect,
// LayerPlaceEffect, SpriteBandEffect) on explicit textures, so the same code runs inside a Media3
// video graph and in the instrumented parity tests without one (ARCH §13.3 "GL effects").
//
// Raster rule of a Media3 chain (MAX_SCALE): LayerLookEffect's `configure` allocates the layer's
// LARGEST footprint round(base·maxScale·renderScale) (capped at 4096 / GL_MAX_TEXTURE_SIZE), so a
// 4K source is downscaled first and a keyframed zoom never softens; each frame then draws the
// raster at that frame's own footprint round(base·|s|·renderScale) into the TOP-LEFT of the
// texture ([LayerFrames.chainRaster]), exactly the API-03 reference renderer's raster. Blur, detail
// (sharpen, vignette, item mask) and place read only that top-left raster (reads clamped to it),
// so every §11.6 stage runs at render resolution in the reference's order and grading never runs
// on a minified copy. The source is not a cap: a source smaller than the footprint is upsampled by
// the look pass like the reference does (sharpen is defined at render resolution).
//
// Every pass first resolves the layer at the frame; null (a gap, a gated frame, opacity 0, scale 0)
// is the early exit: one clear to transparent, no sampling, LUT, blur or detail work.
// Every function runs on the owning GL thread of [ShaderPrograms] and draws into the framebuffer
// bound by the caller (Media3 binds its output texture and sets the full viewport first).

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import kotlin.math.abs
import kotlin.math.max

/** A lazily (re)allocated scratch target that grows to the largest raster requested. */
class ScratchTarget {
    private var target: GlTarget? = null

    /** The target, grown to hold [w] × [h] (not bound). */
    fun obtain(w: Int, h: Int): GlTarget {
        val t = target
        if (t != null && t.width >= w && t.height >= h) return t
        val nw = max(w, t?.width ?: 0)
        val nh = max(h, t?.height ?: 0)
        t?.release()
        return GlTarget.rgba8(nw, nh).also { target = it }
    }

    /** Binds the target grown to [w] × [h] with the viewport on its top-left [w] × [h] px. */
    fun bindTopLeft(w: Int, h: Int): GlTarget {
        val t = obtain(w, h)
        t.bind()
        GLES20.glViewport(0, t.height - h, w, h)
        return t
    }

    /** Deletes the target. */
    fun release() {
        target?.release()
        target = null
    }
}

/** The Media3 effects' per-frame passes (file header). */
object EffectPasses {
    /** Sets the viewport to the top-left [w] × [h] px of a target of height [targetHeight]. */
    fun viewportTopLeft(w: Int, h: Int, targetHeight: Int) = GLES20.glViewport(0, targetHeight - h, w, h)

    /**
     * LayerLookEffect `configure`: the output size for a [inputW] × [inputH] input. MAX_SCALE: the
     * largest footprint of the layer ([maxScale] or the bound frame's own scale); SOURCE: the crop at
     * source resolution; null [b]: the input size (the effect only ever clears).
     */
    fun lookOutputSize(
        b: BoundLayer?,
        maxScale: Double,
        sizing: RasterSizing,
        options: LayerFrameOptions,
        inputW: Int,
        inputH: Int,
        geometry: RenderGeometry,
        maxTextureSize: Int,
    ): Pair<Int, Int> {
        if (b == null) return Pair(inputW, inputH)
        return LayerFrames.rasterSize(
            if (sizing == RasterSizing.SOURCE) RasterSizing.SOURCE else RasterSizing.MAX_SCALE,
            b.params.base,
            max(maxScale, abs(b.params.xf.s)),
            options.cropOverride ?: b.params.crop,
            inputW,
            inputH,
            geometry,
            maxTextureSize,
        )
    }

    /**
     * LayerLookEffect `drawFrame`: the layer raster of [b] from the GL-oriented [inputTex]
     * ([srcW] × [srcH]) into the bound [outW] × [outH] framebuffer (top-left raster, see the file
     * header; SOURCE sizing fills it). [lut] opens the LUT texture of a plan asset.
     */
    fun look(
        programs: ShaderPrograms,
        b: BoundLayer?,
        sizing: RasterSizing,
        options: LayerFrameOptions,
        geometry: RenderGeometry,
        lut: (PlanAsset) -> LutTexture?,
        inputTex: Int,
        srcW: Int,
        srcH: Int,
        outW: Int,
        outH: Int,
    ) {
        programs.checkThread()
        if (b == null) {
            programs.clearTransparent()
            return
        }
        val raster = if (sizing == RasterSizing.SOURCE) {
            Pair(outW, outH)
        } else {
            val place = LayerFrames.place(b.params, geometry, programs.caps.maxTextureSize, options)
            if (place == null) {
                programs.clearTransparent()
                return
            }
            LayerFrames.chainRaster(place, outW, outH)
        }
        val look = LayerFrames.look(b.params, srcW, srcH, raster.first, raster.second, options)
        val lutTexture = look.lutAsset?.let { b.plan.assets[it] }?.let(lut)
        viewportTopLeft(raster.first, raster.second, outH)
        programs.drawLook(SourceTexture(inputTex, srcW, srcH), look, lutTexture, outH)
    }

    /**
     * SeparableBlurEffect `drawFrame`: horizontal pass of the top-left raster of [inputTex]
     * ([w] × [h]) into [tmp], vertical pass into the framebuffer bound by the caller (also
     * [w] × [h]). Below σ 0.5 reference px the raster is copied unchanged.
     */
    fun blur(programs: ShaderPrograms, b: BoundLayer?, geometry: RenderGeometry, inputTex: Int, w: Int, h: Int, tmp: ScratchTarget) {
        programs.checkThread()
        val place = b?.let { LayerFrames.place(it.params, geometry, programs.caps.maxTextureSize) }
        if (b == null || place == null) {
            programs.clearTransparent()
            return
        }
        val (rw, rh) = LayerFrames.chainRaster(place, w, h)
        val blur = LayerFrames.blur(b.params, place, rw, rh, geometry, geometry.canvasW, geometry.canvasH)
        if (blur == null) {
            viewportTopLeft(rw, rh, h)
            programs.drawBlur(inputTex, w, h, true, GaussianKernel.of(0.0), rw, rh, h)
            return
        }
        val out = GlResources.currentFramebuffer()
        val t = tmp.bindTopLeft(rw, rh)
        programs.drawBlur(inputTex, w, h, true, blur.x, rw, rh, t.height)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out)
        viewportTopLeft(rw, rh, h)
        programs.drawBlur(t.texture, t.width, t.height, false, blur.y, rw, rh, h)
    }

    /**
     * LayerPlaceEffect `drawFrame`: detail (sharpen, vignette, item mask) of the top-left raster
     * of [inputTex] ([inW] × [inH]) into [detail] when needed, then placement into the bound
     * canvas-render-size framebuffer (straight alpha, transparent outside the layer). Solids paint
     * the plan colour; sprites and gaps clear.
     */
    fun place(
        programs: ShaderPrograms,
        b: BoundLayer?,
        geometry: RenderGeometry,
        options: LayerFrameOptions,
        inputTex: Int,
        inW: Int,
        inH: Int,
        detail: ScratchTarget,
    ) {
        programs.checkThread()
        val place = b?.let { LayerFrames.place(it.params, geometry, programs.caps.maxTextureSize, options) }
        if (b == null || place == null || b.params.kind == PlanLayerKind.SPRITE) {
            programs.clearTransparent()
            return
        }
        val out = GlResources.currentFramebuffer()
        val outViewport = GlResources.currentViewport()
        if (place.solid != null) {
            programs.drawPlace(0, 1, 1, place, geometry.renderW, geometry.renderH, blend = false)
            return
        }
        val (rw, rh) = LayerFrames.chainRaster(place, inW, inH)
        var tex = inputTex
        var texW = inW
        var texH = inH
        if (place.needsDetail) {
            val t = detail.bindTopLeft(rw, rh)
            programs.drawDetail(tex, texW, texH, rw, rh, place, t.height)
            tex = t.texture
            texW = t.width
            texH = t.height
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out)
            GLES20.glViewport(outViewport[0], outViewport[1], outViewport[2], outViewport[3])
        }
        programs.drawPlace(tex, texW, texH, place, geometry.renderW, geometry.renderH, blend = false, rasterW = rw, rasterH = rh)
    }

    /**
     * SpriteBandEffect `drawFrame`: the active sprite of [b] resampled onto its raster (reveal map
     * applied) in [raster], then placed into the bound canvas-render-size framebuffer. [sprite]
     * opens the sprite texture of a plan asset.
     */
    fun sprite(programs: ShaderPrograms, b: BoundLayer?, geometry: RenderGeometry, sprite: (PlanAsset) -> SpriteTexture, raster: ScratchTarget) {
        programs.checkThread()
        val asset = b?.layer?.asset?.let { b.plan.assets[it] }
        val frame = if (b == null || asset == null || asset.kind != PlanAssetKind.SPRITE || b.params.kind != PlanLayerKind.SPRITE) {
            null
        } else {
            LayerFrames.frame(b.params, geometry, programs.caps.maxTextureSize, reveal = asset.reveal == true)
        }
        if (frame == null || asset == null) {
            programs.clearTransparent()
            return
        }
        val texture = sprite(asset)
        val p = frame.place
        val out = GlResources.currentFramebuffer()
        val outViewport = GlResources.currentViewport()
        val t = raster.bindTopLeft(p.refRasterW, p.refRasterH)
        programs.drawSpriteRaster(texture, p.refRasterW, p.refRasterH, t.height, p.revealShown)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out)
        GLES20.glViewport(outViewport[0], outViewport[1], outViewport[2], outViewport[3])
        programs.drawPlace(t.texture, t.width, t.height, p, geometry.renderW, geometry.renderH, blend = false, rasterW = p.refRasterW, rasterH = p.refRasterH)
    }
}
