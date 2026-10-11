// OWNER: AND-09
//
// LayerRenderer: one layer through the whole effect chain outside Media3 (ARCH §13.3: AND-17's
// LayerCompositorGl / PausedFrameRenderer and AND-16's compositor reuse the same shaders):
// look → (blur H → blur V) → (resample to the reference raster when the raster is larger) →
// (detail: sharpen, vignette, mask) → place for media and image layers, place for solids, sprite
// raster → place for sprites, into a canvas-render-size target, overwriting it or blending onto it. Intermediate
// rasters come from a small pool of RGBA8 targets (the format of Media3's effect textures, so the
// paused frame and the player's frame quantize alike). GlAssetTextures caches LUT and sprite
// textures of plan assets per GL context. Both are confined to their GL thread and release every
// GL object in [release].

package com.vecvel.danaview.editor.engine.effects

import android.content.ContentResolver
import android.net.Uri
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import java.io.File
import java.io.InputStream

/** Draws layers with [programs] (file header). */
class LayerRenderer(val programs: ShaderPrograms) {
    private val confinement = GlThreadConfinement()
    private val free = ArrayList<GlTarget>()
    private var released = false

    /** Pooled intermediate targets currently allocated (in use or free). */
    var allocated: Int = 0
        private set

    private fun obtain(w: Int, h: Int): GlTarget {
        val i = free.indexOfFirst { it.width == w && it.height == h }
        if (i >= 0) return free.removeAt(i)
        allocated++
        return GlTarget.rgba8(w, h)
    }

    private fun recycle(t: GlTarget) {
        free += t
        while (free.size > MAX_FREE) {
            free.removeAt(0).release()
            allocated--
        }
    }

    /**
     * Draws [frame] into [target] ([renderW] × [renderH]; null = the framebuffer bound by the
     * caller, restored afterwards). Media/image layers need [source]; sprites need [sprite]; a LUT
     * frame without [lut] draws without the LUT. With [blend] the layer is composited onto the
     * target, otherwise the target is overwritten (transparent outside the layer).
     */
    fun draw(
        frame: LayerFrame,
        source: SourceTexture?,
        lut: LutTexture?,
        sprite: SpriteTexture?,
        target: GlTarget?,
        renderW: Int,
        renderH: Int,
        blend: Boolean,
    ) {
        confinement.check()
        check(!released) { "renderer released" }
        val outerFbo = GlResources.currentFramebuffer()
        val outerViewport = GlResources.currentViewport()
        fun bindOutput() {
            if (target != null) {
                target.bind()
            } else {
                android.opengl.GLES20.glBindFramebuffer(android.opengl.GLES20.GL_FRAMEBUFFER, outerFbo)
                android.opengl.GLES20.glViewport(outerViewport[0], outerViewport[1], outerViewport[2], outerViewport[3])
            }
        }
        when (frame.kind) {
            PlanLayerKind.SOLID -> {
                bindOutput()
                programs.drawPlace(0, 1, 1, frame.place, renderW, renderH, blend)
            }
            PlanLayerKind.SPRITE -> {
                if (sprite == null) {
                    bindOutput()
                    if (!blend) programs.clearTransparent()
                } else {
                    val p = frame.place
                    val raster = obtain(p.refRasterW, p.refRasterH)
                    try {
                        raster.bind()
                        programs.drawSpriteRaster(sprite, raster.width, raster.height, raster.height, p.revealShown)
                        bindOutput()
                        programs.drawPlace(raster.texture, raster.width, raster.height, p, renderW, renderH, blend)
                    } finally {
                        recycle(raster)
                    }
                }
            }
            PlanLayerKind.MEDIA, PlanLayerKind.IMAGE -> {
                val look = requireNotNull(frame.look) { "picture layer without look" }
                val src = requireNotNull(source) { "picture layer without source" }
                val used = ArrayList<GlTarget>(3)
                try {
                    var raster = obtain(look.rasterW, look.rasterH).also { used += it }
                    raster.bind()
                    programs.drawLook(src, look, lut)
                    val blur = frame.blur
                    if (blur != null) {
                        val tmp = obtain(look.rasterW, look.rasterH).also { used += it }
                        tmp.bind()
                        programs.drawBlur(raster.texture, raster.width, raster.height, true, blur.x)
                        raster.bind()
                        programs.drawBlur(tmp.texture, tmp.width, tmp.height, false, blur.y)
                    }
                    val p = frame.place
                    if (p.needsResample(raster.width, raster.height)) {
                        val small = obtain(p.refRasterW, p.refRasterH).also { used += it }
                        small.bind()
                        programs.drawResample(raster.texture, raster.width, raster.height, small.width, small.height, small.height)
                        raster = small
                    }
                    if (p.needsDetail) {
                        val detail = obtain(raster.width, raster.height).also { used += it }
                        detail.bind()
                        programs.drawDetail(raster.texture, raster.width, raster.height, raster.width, raster.height, p, detail.height)
                        raster = detail
                    }
                    bindOutput()
                    programs.drawPlace(raster.texture, raster.width, raster.height, p, renderW, renderH, blend)
                } finally {
                    for (t in used) recycle(t)
                }
            }
        }
        if (target == null) bindOutput()
    }

    /** Releases the pooled targets (the programs stay with their owner). */
    fun release() {
        confinement.check()
        if (released) return
        released = true
        for (t in free) t.release()
        free.clear()
        allocated = 0
    }

    private companion object {
        const val MAX_FREE = 6
    }
}

/** Opens plan asset URIs (`file://` or `content://`) for LUT and sprite loading. */
fun interface EffectAssets {
    /** Opens [uri]; the caller closes the stream. */
    fun open(uri: String): InputStream

    companion object {
        /** File paths and content URIs through [resolver]. */
        fun of(resolver: ContentResolver): EffectAssets = EffectAssets { uri ->
            if (uri.startsWith("file://")) {
                File(requireNotNull(Uri.parse(uri).path) { "bad file uri" }).inputStream()
            } else {
                requireNotNull(resolver.openInputStream(Uri.parse(uri))) { "cannot open asset" }
            }
        }
    }
}

/**
 * LUT and sprite textures of plan assets on one GL context, keyed by asset URI (file header). LUT
 * tables are decoded once per process ([LutCache]); sprites are decoded on first use and reduced
 * to the context's maxTextureSize.
 */
class GlAssetTextures(private val assets: EffectAssets, private val caps: GlCaps) {
    private val confinement = GlThreadConfinement()
    private val luts = HashMap<String, LutTexture>()
    private val sprites = HashMap<String, SpriteTexture>()

    /** The LUT texture of [asset] (kind `lut`). */
    fun lut(asset: PlanAsset): LutTexture {
        confinement.check()
        return luts.getOrPut(asset.uri) { LutTexture.upload(LutCache.get(asset.uri, assets), caps.isEs3) }
    }

    /** The sprite texture of [asset] (kind `sprite`). */
    fun sprite(asset: PlanAsset): SpriteTexture {
        confinement.check()
        return sprites.getOrPut(asset.uri) {
            val image = assets.open(asset.uri).use { Vsprite.decode(it.readBytes()) }
            SpriteTexture.upload(image, caps.maxTextureSize)
        }
    }

    /** Number of textures held. */
    val size: Int get() = luts.size + sprites.size

    /** Deletes every texture. */
    fun release() {
        confinement.check()
        for (t in luts.values) t.release()
        for (t in sprites.values) t.release()
        luts.clear()
        sprites.clear()
    }
}

/** Process-wide cache of decoded `.vlut` tables (small LRU by URI). */
object LutCache {
    private const val CAPACITY = 16
    private val cache = object : LinkedHashMap<String, LutTable>(CAPACITY, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, LutTable>?): Boolean = size > CAPACITY
    }

    /** The table of [uri], decoded on first use. */
    fun get(uri: String, assets: EffectAssets): LutTable {
        synchronized(cache) { cache[uri]?.let { return it } }
        val table = assets.open(uri).use { LutTable.decode(it.readBytes()) }
        synchronized(cache) { cache[uri] = table }
        return table
    }

    /** Forgets every table. */
    fun clear() = synchronized(cache) { cache.clear() }
}
