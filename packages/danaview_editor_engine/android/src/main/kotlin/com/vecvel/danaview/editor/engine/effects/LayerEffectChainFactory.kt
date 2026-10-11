@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-09

// The production EffectChainFactory (AND-08's interface, composition/EffectChainFactory.kt) for
// Transformer exports (AND-11, AND-19) and any other Media3 composition (ARCH §13.3 "Items",
// "Compositing"): every visual sequence's last effect outputs a canvas-render-size straight-alpha
// texture.
//   MEDIA, IMAGE → [LayerLookEffect, SeparableBlurEffect (only when the layer ever blurs), LayerPlaceEffect]
//   SOLID        → [LayerPlaceEffect] (paints the plan colour over the white source image)
//   SPRITE       → [SpriteBandEffect] (the sequence's active sprite at each frame)
//   GAP          → [LayerPlaceEffect] that always takes the early exit (one clear)
//   CLOCK, BACKGROUND, audio items → no effects.
// Every effect reads the item's layer from the shared AtomicReference<ParamSnapshot> at its frame
// and takes the early exit when its sequence is gated at timeOfFrame(k).

package com.vecvel.danaview.editor.engine.effects

import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.composition.EffectChainFactory
import com.vecvel.danaview.editor.engine.composition.ItemEffectContext
import com.vecvel.danaview.editor.engine.composition.ItemKind

/**
 * AND-09's effect chains (file header). [renderWidth] × [renderHeight] is the compositor output
 * size (Media3Composition.Options output size; null = the plan canvas); [assets] opens LUT and
 * sprite files (null = the Media3 context's ContentResolver).
 */
class LayerEffectChainFactory(
    private val renderWidth: Int? = null,
    private val renderHeight: Int? = null,
    private val assets: EffectAssets? = null,
) : EffectChainFactory {
    override fun videoEffects(context: ItemEffectContext): List<Effect> {
        val spec = context.spec
        val geometry = RenderGeometry(spec.canvasW, spec.canvasH, renderWidth ?: spec.canvasW, renderHeight ?: spec.canvasH)
        val layerId = context.item.layerId
        return when (context.item.kind) {
            ItemKind.MEDIA, ItemKind.IMAGE -> {
                val binding = LayerBinding.of(context.snapshot, context.sequence, requireNotNull(layerId) { "picture item without layer" })
                listOfNotNull(
                    LayerLookEffect(binding, geometry, RasterSizing.MAX_SCALE, assets = assets),
                    if (context.needsBlur) SeparableBlurEffect(binding, geometry) else null,
                    LayerPlaceEffect(binding, geometry),
                )
            }
            ItemKind.SOLID -> listOf(LayerPlaceEffect(LayerBinding.of(context.snapshot, context.sequence, requireNotNull(layerId) { "solid item without layer" }), geometry))
            ItemKind.SPRITE -> listOf(SpriteBandEffect(LayerBinding.of(context.snapshot, context.sequence, layerId), geometry, assets))
            ItemKind.GAP -> listOf(LayerPlaceEffect(LayerBinding.NONE, geometry))
            ItemKind.CLOCK, ItemKind.BACKGROUND, ItemKind.AUDIO, ItemKind.AUDIO_GAP -> emptyList()
        }
    }
}
