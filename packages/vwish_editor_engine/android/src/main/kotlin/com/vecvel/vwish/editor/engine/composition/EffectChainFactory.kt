// OWNER: AND-08
@file:OptIn(UnstableApi::class, ExperimentalApi::class)

// The per-item video effect lists of a composition (ARCH §13.3 "Items", "GL effects"): every
// visual sequence's last effect must output a canvas-render-size straight-alpha texture, so a layer
// item gets `[LayerLookEffect(id), SeparableBlurEffect(id)?, LayerPlaceEffect(id)]` and a gap item
// the place effect's early-exit clear. Those classes are AND-09's (effects/); the mapper reaches
// them only through this interface, which AND-09/AND-11 implement, so the composition package
// never depends on effect internals. [EffectChainFactory.NONE] adds no effects (plain compositing
// of canvas-size sources: the composition tests use it).

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.vwish.editor.engine.plan.ParamSnapshot
import com.vecvel.vwish.editor.engine.plan.PlanLayer
import java.util.concurrent.atomic.AtomicReference

/** What an effect factory knows about one visual item. */
data class ItemEffectContext(
    val spec: CompositionSpec,
    val sequence: SequenceSpec,
    val item: ItemSpec,
    /** The layer of a layer item, or null for gaps and generated images. */
    val layer: PlanLayer?,
    /** The parameter state the effects read at draw time (swapped by param-only patches). */
    val snapshot: AtomicReference<ParamSnapshot>,
    /** Whether the layer ever blurs (static or animated `detail.blur` > 0): add SeparableBlurEffect. */
    val needsBlur: Boolean,
    /** The layer's largest scale (static or keyed `xf.s`), for LayerLookEffect's configure. */
    val maxScale: Double,
)

/** Builds the video effects of each visual item (file header). */
fun interface EffectChainFactory {
    /** Effects of the item in [context], in order. */
    fun videoEffects(context: ItemEffectContext): List<Effect>

    companion object {
        /** No effects. */
        val NONE: EffectChainFactory = EffectChainFactory { emptyList() }
    }
}
