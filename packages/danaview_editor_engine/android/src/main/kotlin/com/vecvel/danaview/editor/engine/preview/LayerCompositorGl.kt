// OWNER: AND-17
//
// LayerCompositorGl (D-36, ARCH §13.3 "Paused edits" and "Frame clock", §11.6 Composite): renders a
// list of per-layer source textures through AND-09's shader programs (LayerLook, optional separable
// blur, detail, LayerPlace; sprites through the sprite raster) into one canvas-render-size target
// and blends them premultiplied source-over onto the opaque background, bottom -> top. It is the
// engine's own twin of the Transformer composition: each layer is drawn by the same passes as the
// Media3 effect chain (LayerRenderer) and blended with the same function DefaultVideoCompositor
// uses (glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA), straight
// layer output onto a premultiplied destination), so a composed frame matches the exported frame
// within the ARCH §11.6 parity tolerance (AND-17 instrumented test PausedParityTest).
//
// Users: AND-17's PausedFrameRenderer (bitmaps of EXACT source frames, TOP_DOWN 2D textures) and
// AND-16's MultiPlayerBackend (deck frames as OES textures of HardwareBuffers). The compositor is
// EGL-agnostic: the caller owns the EGL context, makes it current on danaview-gl and passes either
// a GlTarget or null (= the framebuffer currently bound, e.g. a window surface's framebuffer 0,
// with the viewport already set to the render size).
//
// Evaluation follows D-35: the caller evaluates every layer at t = timeOfFrame(k) of the output
// grid (ParamSnapshot.paramsAt / paramsAtPts) and passes only layers active at t; [activeLayers]
// does both for a ParamSnapshot. Confined to the GL thread that created it (GlThreadConfinement);
// release() frees every GL object it created (pooled rasters, LUT and sprite textures). The
// ShaderPrograms instance belongs to the caller. Never logs paths or user content.

package com.vecvel.danaview.editor.engine.preview

import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.GlAssetTextures
import com.vecvel.danaview.editor.engine.effects.GlTarget
import com.vecvel.danaview.editor.engine.effects.GlThreadConfinement
import com.vecvel.danaview.editor.engine.effects.GlTimerQuery
import com.vecvel.danaview.editor.engine.effects.LayerFrameOptions
import com.vecvel.danaview.editor.engine.effects.LayerFrames
import com.vecvel.danaview.editor.engine.effects.LayerRenderer
import com.vecvel.danaview.editor.engine.effects.LutTexture
import com.vecvel.danaview.editor.engine.effects.RasterSizing
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.effects.ShaderPrograms
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.effects.SpriteTexture
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan

/** Composites layers with AND-09's shaders (file header). */
class LayerCompositorGl(
    /** The programs of the current EGL context (owned by the caller). */
    val programs: ShaderPrograms,
    /** Opens LUT and sprite assets (null: LUTs and sprites are skipped, the layer draws without them). */
    assets: EffectAssets?,
) {
    /**
     * One layer to draw: its [layer] (plan object, for LUT and sprite assets), its [params] at the
     * frame time, the [source] texture of a media/image layer (null for solids and sprites), and
     * the editing-mode [options] (matte, crop override).
     */
    class Input(
        val layer: PlanLayer,
        val params: LayerParams,
        val source: SourceTexture?,
        val options: LayerFrameOptions = LayerFrameOptions(),
    )

    /** What one [compose] drew: layers drawn and skipped, GPU time (null without timer queries) and glFinish-free CPU time. */
    data class Stats(val drawn: Int, val skipped: Int, val gpuNs: Long?, val cpuNs: Long)

    private val confinement = GlThreadConfinement()
    private val renderer = LayerRenderer(programs)
    private val textures: GlAssetTextures? = assets?.let { GlAssetTextures(it, programs.caps) }
    private var released = false

    /** Asset textures (LUTs, sprites) held. */
    val assetTextureCount: Int get() = textures?.size ?: 0

    /** Pooled intermediate rasters currently allocated. */
    val pooledTargets: Int get() = renderer.allocated

    /**
     * Clears [target] (null = the bound framebuffer, viewport set by the caller to
     * [geometry].renderW × renderH) to the plan's opaque `bg`, then draws [inputs] bottom -> top
     * with the compositor blend. A media/image input without a source, or whose placement is
     * degenerate (op <= 0, s = 0), is skipped.
     */
    fun compose(plan: RenderPlan, geometry: RenderGeometry, inputs: List<Input>, target: GlTarget?): Stats {
        confinement.check()
        check(!released) { "compositor released" }
        val started = System.nanoTime()
        var drawn = 0
        var skipped = 0
        val gpu = GlTimerQuery.measureNs(programs.caps) {
            target?.bind()
            programs.clearOpaque(plan.canvas.bg)
            for (input in inputs) {
                if (draw(plan, geometry, input, target)) drawn++ else skipped++
            }
        }
        return Stats(drawn, skipped, gpu, System.nanoTime() - started)
    }

    /** Draws one [input] onto [target] with the compositor blend; false when nothing was drawn. */
    fun draw(plan: RenderPlan, geometry: RenderGeometry, input: Input, target: GlTarget?): Boolean {
        confinement.check()
        check(!released) { "compositor released" }
        val p = input.params
        val picture = p.kind == PlanLayerKind.MEDIA || p.kind == PlanLayerKind.IMAGE
        val source = input.source
        if (picture && source == null) return false
        val frame = LayerFrames.frame(
            p,
            geometry,
            programs.caps.maxTextureSize,
            source?.width ?: 0,
            source?.height ?: 0,
            RasterSizing.FOOTPRINT,
            reveal = true,
            options = input.options,
        ) ?: return false
        val lut = frame.look?.let { look -> LayerFrames.lutAssetOf(look, plan.assets)?.let { lutTexture(it) } }
        val sprite = if (p.kind == PlanLayerKind.SPRITE) input.layer.asset?.let { plan.assets[it] }?.let { spriteTexture(it) } else null
        renderer.draw(frame, source, lut, sprite, target, geometry.renderW, geometry.renderH, blend = true)
        return true
    }

    private fun lutTexture(asset: PlanAsset): LutTexture? {
        val t = textures ?: return null
        return try {
            t.lut(asset)
        } catch (e: Exception) {
            // A missing or broken LUT draws the layer without it (the export reports the asset).
            Log.w(EngineContext.TAG, "paused frame: LUT unavailable (${e.javaClass.simpleName})")
            null
        }
    }

    private fun spriteTexture(asset: PlanAsset): SpriteTexture? {
        val t = textures ?: return null
        return try {
            t.sprite(asset)
        } catch (e: Exception) {
            Log.w(EngineContext.TAG, "paused frame: sprite unavailable (${e.javaClass.simpleName})")
            null
        }
    }

    /** Releases the pooled rasters and the LUT and sprite textures (the programs stay with the caller). */
    fun release() {
        confinement.check()
        if (released) return
        released = true
        renderer.release()
        textures?.release()
    }

    companion object {
        /**
         * The layers of [snapshot] active at plan time [t] (a frame time: `timeOfFrame(k)`), in draw
         * order bottom -> top (ARCH §11.4: z, then t0, then id), with their parameters at [t].
         */
        fun activeLayers(snapshot: ParamSnapshot, t: Long): List<Pair<PlanLayer, LayerParams>> {
            val out = ArrayList<Pair<PlanLayer, LayerParams>>()
            for (base in snapshot.plan.layers) {
                if (!base.covers(t)) continue
                val layer = snapshot.layer(base.id) ?: continue
                val params = snapshot.paramsAt(base.id, t) ?: continue
                out += layer to params
            }
            out.sortWith { a, b -> PlanValidator.compareLayers(a.first, b.first) }
            return out
        }
    }
}
