// OWNER: AND-08
//
// Stacking of the visual layers into sequences (ARCH §13.3 "Sequence stack", §13.5, §11.4).
// Media layers keep the packing slot `seq` the compiler assigned (CORE-36; engines use it as-is):
// one sequence per slot, slot 0 at the bottom. Media3 composites whole sequences in a fixed order,
// so the plan's other visual layers (images, solids such as offline placeholders and transition
// helpers, export sprites), which carry no `seq`, are placed between the slots: a non-media layer
// goes above every slot holding a time-overlapping layer drawn below it and below every slot
// holding a time-overlapping layer drawn above it (draw order = (z, t0, id)). Non-media layers that
// share a position are packed like CORE-36 does (greedy, draw order, one above every overlapping
// one already placed). When no single position satisfies a layer (it overlaps, say, two media
// layers of one slot that sit below and above it), it is split at the edges of the layers it
// overlaps and each piece is placed on its own; adjacent pieces that land together are merged.
// Every pair of time-overlapping layers is then stacked in draw order.

package com.vecvel.danaview.editor.engine.composition

import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanValidator

/** A layer (or a piece of a split non-media layer) inside one sequence: plan range `[t0, t1)`. */
data class StackPiece(val layer: PlanLayer, val t0: Long, val t1: Long)

/** One visual sequence of the stack, bottom → top order in [VisualStack.lanes]. */
data class StackLane(val pieces: List<StackPiece>, val slot: Int?)

/** The stacking result. */
class VisualStack(
    /** Sequences bottom → top. */
    val lanes: List<StackLane>,
    /** Non-media layers that had to be split. */
    val splitLayerIds: Set<String>,
)

/** Computes the [VisualStack] of a plan's visual layers (file header). */
object VisualStacker {
    private class Placed(val piece: StackPiece, val position: Int, var sub: Int = 0)

    /** Stacks [layers] (any order; the plan's visual layers). */
    fun stack(layers: List<PlanLayer>): VisualStack {
        val media = layers.filter { it.kind == PlanLayerKind.MEDIA }
        val slots = media.mapNotNull { it.seq }.distinct().sorted()
        val rank = slots.withIndex().associate { (i, s) -> s to i }
        val n = slots.size
        val others = layers.filter { it.kind != PlanLayerKind.MEDIA }.sortedWith(PlanValidator::compareLayers)

        val placed = ArrayList<Placed>()
        val split = HashSet<String>()

        fun overlaps(a0: Long, a1: Long, b0: Long, b1: Long) = a0 < b1 && b0 < a1

        /** (lo, hi) bounds of a piece of [l] over [t0, t1). */
        fun bounds(l: PlanLayer, t0: Long, t1: Long): Pair<Int, Int> {
            var lo = 0
            var hi = n
            for (m in media) {
                if (!overlaps(m.t0, m.t1, t0, t1)) continue
                val r = rank.getValue(m.seq!!)
                if (PlanValidator.compareLayers(m, l) < 0) lo = maxOf(lo, r + 1) else hi = minOf(hi, r)
            }
            for (p in placed) {
                if (overlaps(p.piece.t0, p.piece.t1, t0, t1)) lo = maxOf(lo, p.position)
            }
            return lo to hi
        }

        for (l in others) {
            val (lo, hi) = bounds(l, l.t0, l.t1)
            if (lo <= hi) {
                placed += Placed(StackPiece(l, l.t0, l.t1), lo)
                continue
            }
            // Split at every edge of the layers and pieces it overlaps.
            split += l.id
            val cuts = sortedSetOf(l.t0, l.t1)
            for (m in media) if (overlaps(m.t0, m.t1, l.t0, l.t1)) { cuts += m.t0; cuts += m.t1 }
            for (p in placed) if (overlaps(p.piece.t0, p.piece.t1, l.t0, l.t1)) { cuts += p.piece.t0; cuts += p.piece.t1 }
            val edges = cuts.filter { it in l.t0..l.t1 }
            var pending: Placed? = null
            for (i in 0 until edges.size - 1) {
                val a = edges[i]
                val b = edges[i + 1]
                val (plo, _) = bounds(l, a, b)
                val prev = pending
                pending = if (prev != null && prev.position == plo && prev.piece.t1 == a) {
                    Placed(StackPiece(l, prev.piece.t0, b), plo)
                } else {
                    prev?.let { placed += it }
                    Placed(StackPiece(l, a, b), plo)
                }
            }
            pending?.let { placed += it }
        }

        // Pack the pieces of each position (draw order, then time).
        val byPosition = placed.groupBy { it.position }
        val lanes = ArrayList<StackLane>()
        for (p in 0..n) {
            val group = byPosition[p].orEmpty().sortedWith(
                Comparator<Placed> { a, b -> PlanValidator.compareLayers(a.piece.layer, b.piece.layer) }.thenBy { it.piece.t0 },
            )
            val done = ArrayList<Placed>()
            for (x in group) {
                var sub = 0
                for (y in done) {
                    if (overlaps(x.piece.t0, x.piece.t1, y.piece.t0, y.piece.t1)) sub = maxOf(sub, y.sub + 1)
                }
                x.sub = sub
                done += x
            }
            val subCount = (done.maxOfOrNull { it.sub } ?: -1) + 1
            for (s in 0 until subCount) {
                lanes += StackLane(done.filter { it.sub == s }.map { it.piece }.sortedBy { it.t0 }, null)
            }
            if (p < n) {
                val slot = slots[p]
                lanes += StackLane(media.filter { it.seq == slot }.sortedBy { it.t0 }.map { StackPiece(it, it.t0, it.t1) }, slot)
            }
        }
        return VisualStack(lanes, split)
    }
}
