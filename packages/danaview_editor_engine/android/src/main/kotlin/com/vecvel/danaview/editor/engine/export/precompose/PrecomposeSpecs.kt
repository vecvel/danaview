// OWNER: AND-19
//
// Composition specs of the precompose passes (ARCH D-45(B), §13.3 "Sequence stack", §14.3).
// Pure and JVM-tested: it cuts AND-08's mapped export composition (CompositionSpec) at lane
// boundaries instead of re-planning layers, so every lane keeps exactly the items, layer pieces,
// gating ranges and stacking order the single-pass export would have used (non-media layers that
// VisualStacker split keep their pieces; no layer is re-timed or re-ordered).
//
// Intermediate pass n over lanes [from, to) (bottom → top indices of PrecomposePlanner.lanes):
//   0        the clock band, trackTypes {VIDEO} only (the intermediate is video only; audio is
//            mixed once in the final pass);
//   1..m     lanes to−1 … from (top → bottom), unchanged;
//   m+1      pass ≥ 2: the previous intermediate as an ordinary MEDIA lane (below);
//   last     the opaque background.
//   No audio sequences. Mapped from the PADDED plan (durUs + one grid frame, PrecomposePlanner).
// Final pass over lanes [finalFrom, laneCount):
//   0 the clock band ({VIDEO, AUDIO}, a silent AAC track always exists, D-38), the remaining lanes
//   top → bottom, the last intermediate, the background, then every audio sequence of the plan.
//   Mapped from the plan itself (durUs), so the output equals a single pass in length and audio.
// The intermediate lane comes from mapping a one-layer plan through the same mapper: a MEDIA layer
// `precompose:pre-<n>` (z 0, seq 0, identity placement, base = the canvas, so it fills the render
// target exactly as the lanes below the cut did) over [0, durUs) at rate 1, its asset the
// intermediate file (VIDEO, SDR, export size). The mapper clips it at the rule frame of 0 (ARCH
// §13.3 SNAP_TO_RULE_FRAME) and the gating keeps it shown on every output frame of the export grid.
// Sequence indices are renumbered to their list position (compositor input id = sequence index).

package com.vecvel.danaview.editor.engine.export.precompose

import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.SequenceSpec
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.File

/** One intermediate as a plan layer (file header). */
class IntermediateLayer(val number: Int, val file: File, val layer: PlanLayer, val asset: PlanAsset) {
    val assetId: String get() = requireNotNull(layer.asset)
}

/** Pass composition specs (file header). */
object PrecomposeSpecs {
    /** `pre-<n>.mp4` in [workDir]. */
    fun intermediateFile(workDir: File, number: Int): File = File(workDir, "pre-$number.mp4")

    /** [plan] lasting one more grid frame (intermediate passes, PrecomposePlanner). */
    fun paddedPlan(plan: RenderPlan): RenderPlan = plan.copy(durUs = PrecomposePlanner.paddedDurationUs(plan))

    /** An id not used by [plan]'s layers or assets. */
    private fun freeId(plan: RenderPlan, base: String): String {
        var id = base
        var i = 1
        while (plan.layers.any { it.id == id } || plan.assets.containsKey(id)) id = "$base~${i++}"
        return id
    }

    /**
     * Intermediate [number] in [file] as a layer of [plan]: covers [0, [visibleUs]) at rate 1 and
     * fills the canvas; its asset lasts [fileDurationUs] (the padded duration it was rendered over).
     */
    fun intermediate(plan: RenderPlan, number: Int, file: File, width: Int, height: Int, visibleUs: Long, fileDurationUs: Long): IntermediateLayer {
        val id = freeId(plan, "precompose:pre-$number")
        val asset = PlanAsset(
            kind = PlanAssetKind.VIDEO,
            uri = "file://" + file.absolutePath,
            fp = "precompose-$number",
            w = width,
            h = height,
            rot = 0,
            durUs = fileDurationUs,
            hasAudio = false,
        )
        val layer = PlanLayer(
            id = id,
            z = 0,
            seq = 0,
            t0 = 0,
            t1 = visibleUs,
            kind = PlanLayerKind.MEDIA,
            asset = id,
            map = listOf(MapSegment(0, visibleUs, 0, visibleUs)),
        )
        return IntermediateLayer(number, file, layer, asset)
    }

    /** The one-layer plan the mapper turns into the intermediate's lane (same canvas, [durUs]). */
    fun intermediatePlan(plan: RenderPlan, durUs: Long, i: IntermediateLayer): RenderPlan = RenderPlan(
        rev = plan.rev,
        target = plan.target,
        canvas = plan.canvas,
        durUs = durUs,
        assets = mapOf(i.assetId to i.asset),
        layers = listOf(i.layer),
        audio = emptyList(),
    )

    /** The plan the pass's effects read their parameters from: [plan] plus [i]'s layer and asset. */
    fun snapshotPlan(plan: RenderPlan, i: IntermediateLayer?): RenderPlan =
        if (i == null) plan else plan.copy(assets = plan.assets + (i.assetId to i.asset), layers = listOf(i.layer) + plan.layers)

    /** The lane sequence of a mapped [intermediatePlan]. */
    fun intermediateLane(mapped: CompositionSpec): SequenceSpec = mapped.slotSequences.single()

    /** Lanes `[from, to)` of [full] (bottom → top indices), returned top → bottom. */
    fun lanesTopDown(full: CompositionSpec, from: Int, to: Int): List<SequenceSpec> {
        val bottomUp = full.layerSequences.asReversed()
        require(from in 0..to && to <= bottomUp.size) { "lane range" }
        return bottomUp.subList(from, to).asReversed()
    }

    /** Intermediate pass spec (file header): lanes `[from, to)` of the padded [full] over [input] or the background. */
    fun passSpec(full: CompositionSpec, from: Int, to: Int, input: SequenceSpec?, inputLayer: IntermediateLayer?): CompositionSpec {
        val clock = full.sequences.first { it.kind == SequenceKind.CLOCK_BAND }.copy(trackTypes = TrackTypes.VIDEO)
        val background = full.sequences.first { it.kind == SequenceKind.BACKGROUND }
        return assemble(full, listOf(clock) + lanesTopDown(full, from, to) + listOfNotNull(input) + background, inputLayer)
    }

    /** Final pass spec (file header): lanes `[from, end)` of [full] over [input], with the plan's audio. */
    fun finalSpec(full: CompositionSpec, from: Int, input: SequenceSpec?, inputLayer: IntermediateLayer?): CompositionSpec {
        val clock = full.sequences.first { it.kind == SequenceKind.CLOCK_BAND }
        val background = full.sequences.first { it.kind == SequenceKind.BACKGROUND }
        val lanes = lanesTopDown(full, from, full.layerSequences.size)
        return assemble(full, listOf(clock) + lanes + listOfNotNull(input) + background + full.audioSequences, inputLayer)
    }

    private fun assemble(full: CompositionSpec, sequences: List<SequenceSpec>, inputLayer: IntermediateLayer?): CompositionSpec = full.copy(
        sequences = sequences.mapIndexed { i, s -> if (s.index == i) s else s.copy(index = i) },
        layers = if (inputLayer == null) full.layers else full.layers + (inputLayer.layer.id to inputLayer.layer),
    )
}
