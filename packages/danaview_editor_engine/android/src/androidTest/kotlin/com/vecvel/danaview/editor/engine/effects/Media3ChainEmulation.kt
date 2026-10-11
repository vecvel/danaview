// OWNER: AND-09
//
// Runs one layer through the Media3 effect chain of LayerEffectChainFactory without a Media3 video
// graph: the same EffectPasses calls the GlEffect programs make, on RGBA8 textures sized exactly
// as Media3 sizes them (LayerLookEffect `configure` via EffectPasses.lookOutputSize from the live
// LayerBinding; the blur texture = the look texture; LayerPlaceEffect / SpriteBandEffect output =
// canvas render size), then blends the straight-alpha output premultiplied source-over onto a CPU
// frame like DefaultVideoCompositor (glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE,
// ONE_MINUS_SRC_ALPHA)). Media3ChainGlTest checks the real Media3 programs against this emulation.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot

/** The Media3 chain on explicit textures (file header). Confined to the GL thread. */
class Media3ChainEmulation {
    private val tmp = ScratchTarget()
    private val detail = ScratchTarget()
    private val spriteRaster = ScratchTarget()
    private val targets = HashMap<Triple<Int, Int, Int>, GlTarget>()

    private fun target(w: Int, h: Int, slot: Int): GlTarget = targets.getOrPut(Triple(w, h, slot)) { GlTarget.rgba8(w, h) }

    /**
     * Draws [layer] at the frame stamped [ptsUs] through [binding] (the item's effect binding) from
     * the GL-oriented source [srcTex] ([srcW] × [srcH]; 0 for solids and sprites) and blends the
     * place output onto [frame] (RGBA doubles, top-down, [w] × [h] = the render size). Returns the
     * place output (straight RGBA8, top-down).
     */
    fun draw(
        programs: ShaderPrograms,
        layer: PlanLayer,
        binding: LayerBinding,
        ptsUs: Long,
        geometry: RenderGeometry,
        srcTex: Int,
        srcW: Int,
        srcH: Int,
        sprite: SpriteTexture?,
        lut: (PlanAsset) -> LutTexture?,
        frame: DoubleArray?,
        w: Int,
        h: Int,
    ): ByteArray {
        val b = binding.resolve(ptsUs)
        val out = target(w, h, 0)
        when (layer.kind) {
            PlanLayerKind.MEDIA, PlanLayerKind.IMAGE -> {
                val opts = LayerFrameOptions()
                val (lw, lh) = EffectPasses.lookOutputSize(
                    binding.current(), binding.maxScale, RasterSizing.MAX_SCALE, opts, srcW, srcH, geometry, programs.caps.maxTextureSize,
                )
                val look = target(lw, lh, 1)
                look.bind()
                EffectPasses.look(programs, b, RasterSizing.MAX_SCALE, opts, geometry, lut, srcTex, srcW, srcH, lw, lh)
                var input = look
                if (ParamSnapshot.needsBlur(layer)) {
                    val blurred = target(lw, lh, 2)
                    blurred.bind()
                    EffectPasses.blur(programs, b, geometry, look.texture, lw, lh, tmp)
                    input = blurred
                }
                out.bind()
                EffectPasses.place(programs, b, geometry, opts, input.texture, lw, lh, detail)
            }
            PlanLayerKind.SOLID -> {
                out.bind()
                EffectPasses.place(programs, b, geometry, LayerFrameOptions(), 0, 1, 1, detail)
            }
            PlanLayerKind.SPRITE -> {
                out.bind()
                EffectPasses.sprite(programs, b, geometry, { requireNotNull(sprite) { "sprite texture" } }, spriteRaster)
            }
        }
        out.bind()
        val rgba = GlTestEnv.readRgba8(w, h)
        if (frame != null) {
            for (i in 0 until w * h) {
                val a = (rgba[i * 4 + 3].toInt() and 0xFF) / 255.0
                if (a == 0.0) continue
                for (c in 0 until 3) {
                    val s = (rgba[i * 4 + c].toInt() and 0xFF) / 255.0
                    frame[i * 4 + c] = s * a + frame[i * 4 + c] * (1 - a)
                }
                frame[i * 4 + 3] = a + frame[i * 4 + 3] * (1 - a)
            }
        }
        return rgba
    }

    /** Deletes every texture. */
    fun release() {
        for (t in targets.values) t.release()
        targets.clear()
        tmp.release()
        detail.release()
        spriteRaster.release()
    }
}
