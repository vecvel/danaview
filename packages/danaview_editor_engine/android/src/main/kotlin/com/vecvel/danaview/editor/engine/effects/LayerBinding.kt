// OWNER: AND-09
//
// How an effect finds what to draw at a Media3 frame (ARCH §13.3 "GL effects", D-35): params are
// read from the AtomicReference<ParamSnapshot> at drawFrame(ptsUs), with k = frameIndexNearest(pts)
// of the output rate and every channel evaluated at timeOfFrame(k), never at the raw pts. Early exit
// (review issue 3): when timeOfFrame(k) is outside the sequence's layers (a gap, or a frame the
// compositor gates), [resolve] returns null and the effect clears to transparent without sampling,
// LUT or blur work. Effect pts are composition times (sequence-cumulative, AND-01 V-N2).

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.composition.SequenceSpec
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.util.concurrent.atomic.AtomicReference

/** One layer evaluated at one output frame. */
class BoundLayer(val params: LayerParams, val layer: PlanLayer, val plan: RenderPlan)

/** The layer an effect draws (file header). */
interface LayerBinding {
    /** The layer at the frame stamped [ptsUs], or null for the early exit. */
    fun resolve(ptsUs: Long): BoundLayer?

    /** The bound layer at its first frame (Media3 `configure`), or null. */
    fun current(): BoundLayer?

    /** The layer's largest scale (static or animated `xf.s`) for raster sizing. */
    val maxScale: Double

    companion object {
        /** Never draws (gap items: one clear per frame). */
        val NONE: LayerBinding = object : LayerBinding {
            override fun resolve(ptsUs: Long): BoundLayer? = null
            override fun current(): BoundLayer? = null
            override val maxScale: Double = 1.0
        }

        /**
         * The layer [layerId] of the live [snapshot], gated by [sequence] (null: no gating). With
         * [layerId] null the sequence's active layer at each frame is drawn (sprite bands).
         */
        fun of(snapshot: AtomicReference<ParamSnapshot>, sequence: SequenceSpec?, layerId: String?): LayerBinding =
            SnapshotLayerBinding(snapshot, sequence, layerId)

        /** Always [params] of [layer] (look stills: no time, no gating). */
        fun fixed(params: LayerParams, layer: PlanLayer, plan: RenderPlan): LayerBinding = object : LayerBinding {
            private val bound = BoundLayer(params, layer, plan)
            override fun resolve(ptsUs: Long): BoundLayer = bound
            override fun current(): BoundLayer = bound
            override val maxScale: Double = kotlin.math.abs(params.xf.s)
        }
    }
}

/** [LayerBinding.of]. */
private class SnapshotLayerBinding(
    private val snapshot: AtomicReference<ParamSnapshot>,
    private val sequence: SequenceSpec?,
    private val layerId: String?,
) : LayerBinding {
    override fun resolve(ptsUs: Long): BoundLayer? {
        val snap = snapshot.get()
        val t = snap.frameTimeOf(ptsUs)
        val id = if (sequence != null) {
            val active = sequence.activeAt(t) ?: return null
            layerId ?: active.layerId
        } else {
            layerId ?: return null
        }
        val layer = snap.layer(id) ?: return null
        return BoundLayer(ParamSnapshot.evaluate(layer, snap.plan, t), layer, snap.plan)
    }

    override fun current(): BoundLayer? {
        val snap = snapshot.get()
        val id = layerId ?: sequence?.active?.firstOrNull()?.layerId ?: return null
        val layer = snap.layer(id) ?: return null
        return BoundLayer(ParamSnapshot.evaluate(layer, snap.plan, layer.t0), layer, snap.plan)
    }

    override val maxScale: Double
        get() = layerId?.let { snapshot.get().layer(it) }?.let { ParamSnapshot.maxScale(it) } ?: 1.0
}
