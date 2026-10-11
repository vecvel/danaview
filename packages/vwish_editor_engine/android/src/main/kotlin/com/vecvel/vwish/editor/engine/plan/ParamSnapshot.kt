// OWNER: AND-08
//
// ParamSnapshot (ARCH §11.2 "Patch classification", §13.3 "GL effects"): the immutable parameter
// state the GL effects (AND-09), the paused-frame renderer (AND-17) and the preview session
// (AND-10, AND-16) read from an `AtomicReference<ParamSnapshot>`. A param-only patch or a transient
// swaps the reference; nothing else changes. Evaluation follows the platform-time rule (D-35): a
// platform time (Media3 effect / compositor pts, a deck frame pts) becomes
// `k = frameIndexNearest(pts)` of the OUTPUT rate and every channel is evaluated at
// `t = timeOfFrame(k)`, never at the raw pts. The per-layer evaluation is the twin of API-03's
// Dart `LayerParamSnapshot.at` (keyframes.json vectors).

package com.vecvel.vwish.editor.engine.plan

/**
 * One layer's effective parameters at one plan time: [xf] with its centre resolved to canvas px and
 * animated channels applied, [base] resolved (missing = canvas size, or `sw/sscale × sh/sscale` for
 * sprites), [adj] / [detail] present when static or animated, [mask] only for a static mask (its
 * shape is not animatable), [reveal] only when the channel exists, canvas masks with their `anim`
 * applied (and cleared).
 */
data class LayerParams(
    val id: String,
    val kind: PlanLayerKind,
    val t: Long,
    val xf: PlanTransform,
    val base: PlanSize,
    val crop: PlanCrop,
    val adj: PlanAdjust?,
    val detail: PlanDetail?,
    val lut: PlanLut?,
    val chroma: PlanChroma?,
    val mask: PlanMask?,
    val reveal: Double?,
    val cmasks: List<CanvasMask>,
    val color: Int?,
)

/** Immutable parameter state of one plan revision plus the live transients (file header). */
class ParamSnapshot private constructor(
    /** The committed plan (transients are not part of it). */
    val plan: RenderPlan,
    /** Live transients by item id (ARCH §11.2 Transient; last write wins). */
    val transients: Map<String, PlanTransient>,
    private val effective: Map<String, PlanLayer>,
) {
    /** The plan revision. */
    val rev: Long get() = plan.rev

    /** The plan canvas. */
    val canvas: PlanCanvas get() = plan.canvas

    /** Output frame grid (platform times map onto it). */
    val outputGrid: FrameGrid = FrameGrid.of(plan.canvas.fps)

    /** The effective layer [id] (plan layer with its transient merged), or null. */
    fun layer(id: String): PlanLayer? = effective[id]

    /** Output frame index of a platform time: `frameIndexNearest(pts)` (D-35). */
    fun frameIndexOf(ptsUs: Long): Long = outputGrid.frameIndexNearest(ptsUs)

    /** Plan time an output frame stamped [ptsUs] is evaluated at: `timeOfFrame(frameIndexNearest(pts))`. */
    fun frameTimeOf(ptsUs: Long): Long = outputGrid.frameTimeOf(ptsUs)

    /** Whether layer [id] covers plan time [t] (half-open `[t0, t1)`). */
    fun isActive(id: String, t: Long): Boolean = effective[id]?.covers(t) == true

    /** Parameters of layer [id] at the output frame stamped with platform time [ptsUs] (D-35). */
    fun paramsAtPts(id: String, ptsUs: Long): LayerParams? = paramsAt(id, frameTimeOf(ptsUs))

    /** Parameters of layer [id] evaluated at plan time [t] (already a frame time), or null. */
    fun paramsAt(id: String, t: Long): LayerParams? {
        val l = effective[id] ?: return null
        return evaluate(l, plan, t)
    }

    /** This snapshot with [transient] merged (replacing the item's previous transient). */
    fun withTransient(transient: PlanTransient): ParamSnapshot {
        val next = LinkedHashMap(transients)
        next[transient.item] = transient
        return build(plan, next)
    }

    /** This snapshot without the transient of [item]. */
    fun withoutTransient(item: String): ParamSnapshot =
        if (!transients.containsKey(item)) this else build(plan, transients - item)

    /**
     * The snapshot of [next] (a new plan or a patched plan). A transient is dropped when the
     * plan/patch touches one of its layers (ARCH §11.2): a layer that changed or disappeared, or any
     * layer id in [touchedLayerIds] (a patch's upserts and removals).
     */
    fun withPlan(next: RenderPlan, touchedLayerIds: Set<String> = emptySet()): ParamSnapshot {
        val oldById = plan.layers.associateBy { it.id }
        val newById = next.layers.associateBy { it.id }
        val kept = transients.filterValues { tr ->
            tr.layers.none { tl ->
                tl.id in touchedLayerIds || newById[tl.id] == null || newById[tl.id] != oldById[tl.id]
            }
        }
        return build(next, kept)
    }

    companion object {
        /** The snapshot of [plan] without transients. */
        fun of(plan: RenderPlan): ParamSnapshot = build(plan, emptyMap())

        private fun build(plan: RenderPlan, transients: Map<String, PlanTransient>): ParamSnapshot {
            val effective = LinkedHashMap<String, PlanLayer>(plan.layers.size * 2)
            for (l in plan.layers) effective[l.id] = l
            for (tr in transients.values) {
                for (tl in tr.layers) {
                    val l = effective[tl.id] ?: continue
                    effective[tl.id] = PlanPatches.mergeTransient(l, tl)
                }
            }
            return ParamSnapshot(plan, transients, effective)
        }

        /** Evaluates [layer] of [plan] at plan time [t] (API-03 `LayerParamSnapshot.at`). */
        fun evaluate(layer: PlanLayer, plan: RenderPlan, t: Long): LayerParams {
            val anim = layer.anim
            fun v(channel: String, fallback: Double): Double {
                val keys = anim[channel]
                return if (keys == null || keys.isEmpty()) fallback else keys.valueAt(t)
            }
            val canvas = plan.canvas
            val x = layer.xf
            val xf = PlanTransform(
                cx = v(PlanChannels.XF_CX, x.cx ?: canvas.w / 2.0),
                cy = v(PlanChannels.XF_CY, x.cy ?: canvas.h / 2.0),
                s = v(PlanChannels.XF_S, x.s),
                r = v(PlanChannels.XF_R, x.r),
                fx = x.fx,
                fy = x.fy,
                op = v(PlanChannels.XF_OP, x.op),
            )
            var adj = layer.fx.adj
            if (adj != null || PlanChannels.ADJUST.any { anim.containsKey(it) }) {
                val a = adj ?: PlanAdjust()
                adj = PlanAdjust(
                    exposure = v("adj.exposure", a.exposure),
                    brightness = v("adj.brightness", a.brightness),
                    contrast = v("adj.contrast", a.contrast),
                    highlights = v("adj.highlights", a.highlights),
                    shadows = v("adj.shadows", a.shadows),
                    saturation = v("adj.saturation", a.saturation),
                    temperature = v("adj.temperature", a.temperature),
                    tint = v("adj.tint", a.tint),
                )
            }
            var detail = layer.fx.detail
            if (detail != null || PlanChannels.DETAIL.any { anim.containsKey(it) }) {
                val d = detail ?: PlanDetail()
                detail = PlanDetail(
                    sharpen = v("detail.sharpen", d.sharpen),
                    blur = v("detail.blur", d.blur),
                    vignette = v("detail.vignette", d.vignette),
                )
            }
            val m = layer.fx.mask
            val mask = m?.copy(
                cx = v("mask.cx", m.cx),
                cy = v("mask.cy", m.cy),
                w = v("mask.w", m.w),
                h = v("mask.h", m.h),
                r = v("mask.r", m.r),
                feather = v("mask.feather", m.feather),
                op = v("mask.op", m.op),
            )
            val revealKeys = anim[PlanChannels.REVEAL]
            return LayerParams(
                id = layer.id,
                kind = layer.kind,
                t = t,
                xf = xf,
                base = resolvedBase(layer, plan),
                crop = layer.crop,
                adj = adj,
                detail = detail,
                lut = layer.fx.lut,
                chroma = layer.fx.chroma,
                mask = mask,
                reveal = if (revealKeys == null || revealKeys.isEmpty()) null else revealKeys.valueAt(t),
                cmasks = layer.cmasks.map { evaluateCanvasMask(it, t) },
                color = layer.color,
            )
        }

        /** A canvas mask with its `anim` channels evaluated at [t] (the result has no `anim`). */
        fun evaluateCanvasMask(m: CanvasMask, t: Long): CanvasMask {
            fun v(c: String, fallback: Double): Double {
                val keys = m.anim[c]
                return if (keys == null || keys.isEmpty()) fallback else keys.valueAt(t)
            }
            return CanvasMask(cx = v("cx", m.cx), cy = v("cy", m.cy), w = v("w", m.w), h = v("h", m.h), r = m.r, feather = m.feather, inv = m.inv)
        }

        /** `base`, or the canvas size, or `sw/sscale × sh/sscale` for a sprite without one. */
        fun resolvedBase(layer: PlanLayer, plan: RenderPlan): PlanSize {
            layer.base?.let { return it }
            if (layer.kind == PlanLayerKind.SPRITE) {
                val a = layer.asset?.let { plan.assets[it] }
                val sw = a?.sw
                val sh = a?.sh
                val sscale = a?.sscale
                if (sw != null && sh != null && sscale != null && sscale > 0) return PlanSize(sw / sscale, sh / sscale)
            }
            return PlanSize(plan.canvas.w.toDouble(), plan.canvas.h.toDouble())
        }

        /**
         * The largest scale [layer] reaches (static `xf.s` or its animated keys), used by
         * LayerLookEffect's `configure` to downscale 4K sources first without softening zooms.
         */
        fun maxScale(layer: PlanLayer): Double {
            val keys = layer.anim[PlanChannels.XF_S]
            if (keys == null || keys.isEmpty()) return layer.xf.s
            var max = 0.0
            for (i in 0 until keys.size) max = maxOf(max, keys.valueOf(i))
            return max
        }

        /** Whether [layer] ever needs a blur pass (static or animated `detail.blur` > 0). */
        fun needsBlur(layer: PlanLayer): Boolean {
            if ((layer.fx.detail?.blur ?: 0.0) > 0) return true
            val keys = layer.anim["detail.blur"] ?: return false
            return (0 until keys.size).any { keys.valueOf(it) > 0 }
        }
    }
}
