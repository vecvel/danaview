// OWNER: AND-19
//
// The pure planning half of the multi-pass export precompose (ARCH D-45(B), §14.3 "Multi-pass
// precompose"; BUILD_PLAN AND-19). JVM-tested; nothing here touches Media3 or the file system.
//
// Input: the visual lanes of the packed export plan, bottom → top, exactly as AND-08's mapper
// stacks them (VisualStacker: one lane per packing slot `seq`, plus the lanes of non-media layers
// between them), and the device's DecoderBudget (Capabilities.maxVisualSequences and codec
// maxSupportedInstances − 2, AND-11's MultiPassRouting rule).
// Split (greedy, deterministic): pass 1 takes the lowest lanes up to the highest slot lane whose
// cumulative load still fits the budget (slots ≤ maxVisualSequences, peak simultaneous media
// layers ≤ maxDecoders); every later pass reads the previous intermediate as one more slot that is
// active over the whole duration (one decoder at every instant) and takes the next lanes the same
// way; as soon as the remaining lanes plus the intermediate fit, they are the final pass. A pass
// always takes at least one slot lane, so the split terminates; when even one slot plus the
// intermediate exceeds the budget (maxVisualSequences 1, or maxDecoders 1) that pass runs over
// budget and is counted in [PrecomposePlan.overBudgetPasses] (export never refuses, D-43(e) 7).
// Because a lane cut never reorders lanes and every intermediate is the opaque composite of
// everything below the cut, blending order is unchanged (D-45(B)).
//
// Intermediates (`work/export-<jobId>/pre-<n>.mp4`): the export codec, size and frame rate, all
// intra (I-frame interval 0) AND requested at 4× the export bitrate (Transformer's encoder fallback
// may clamp the bitrate to what the encoder supports; all-intra is kept either way), rendered over
// the plan duration plus one grid frame ([paddedDurationUs]) so the final pass can clip exactly
// `durUs` of it at rate 1 whatever duration the muxer writes.
// Colour: intermediates are encoded and signalled as BT.601 limited-range SDR (they are already
// tone-mapped; HDR never reaches them). Measured on the API 35 emulator (2026-10-15): with Media3's
// default BT.709 encoder configuration, every intermediate round trip shifted colours by one
// 709-encode / 601-decode step (the emulator's GL converts decoded H.264 with BT.601 whatever the
// stream signals, AND-06), e.g. a background (89, 35, 45) became (79, 21, 46) after two
// intermediates and per-frame SSIM against the single pass fell to 0.975; with BT.601
// intermediates the round trip is consistent (SSIM ≥ 0.996) on a decoder that ignores the
// signalled matrix the way the emulator does, and on any decoder that honours it. The export
// itself keeps Media3's colour (BT.709). QA-04 re-checks on devices.
// Disk: an intermediate is estimated like an export ((bitrate) · seconds / 8 · 1.02, ARCH §14.1,
// video only); pass n ≥ 2 holds its input and its output, the final pass holds the last
// intermediate and the output, so the peak is max(2·I, I + output) (I + output with one pass).
// Progress weights: each pass costs the sequences it decodes or draws (its lanes, plus the
// background, plus the intermediate it reads); the final pass also mixes audio.

package com.vecvel.danaview.editor.engine.export.precompose

import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.SequenceSpec
import com.vecvel.danaview.editor.engine.export.DecoderBudget
import com.vecvel.danaview.editor.engine.export.EncoderSettings
import com.vecvel.danaview.editor.engine.export.MultiPassRouting
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.RenderPlan

/** The YUV colour encoding of intermediates. */
enum class IntermediateColor {
    /** Whatever Media3 configures for the export's own encoder (BT.709 limited for SDR; see the file header). */
    EXPORT,

    /** BT.601 limited range, signalled in the stream (the default, file header). */
    BT601,
}

/** A half-open plan-time span `[t0, t1)` of one media layer. */
data class MediaSpan(val t0: Long, val t1: Long)

/** One visual lane of the export stack (bottom → top order in the planner's lists). */
data class PlannerLane(
    /** The lane is a packing slot (decoder-backed media layers). */
    val isSlot: Boolean,
    /** The media layers' spans (empty for non-media lanes). */
    val media: List<MediaSpan> = emptyList(),
)

/** One intermediate pass: lanes `[from, to)` (bottom → top indices) into `pre-<number>.mp4`. */
data class PassRange(
    val number: Int,
    val from: Int,
    val to: Int,
    /** The pass reads `pre-<number − 1>.mp4` as its bottom layer. */
    val readsIntermediate: Boolean,
    /** Its decoder load (the intermediate it reads included). */
    val load: MultiPassRouting.Load,
    /** The load exceeds the budget (a forced single-slot step, see the file header). */
    val overBudget: Boolean,
)

/** The pass split of one export (file header). */
data class PrecomposePlan(
    /** Intermediate passes, bottom first (empty: the whole stack fits; one ordinary pass). */
    val passes: List<PassRange>,
    /** The final pass draws lanes `[finalFrom, laneCount)` over the last intermediate. */
    val finalFrom: Int,
    val laneCount: Int,
    /** The final pass's load (the intermediate included when there is one). */
    val finalLoad: MultiPassRouting.Load,
    /** The final pass exceeds the budget. */
    val finalOverBudget: Boolean,
) {
    /** Number of intermediates written. */
    val intermediateCount: Int get() = passes.size

    /** Intermediate passes plus the final pass. */
    val totalPasses: Int get() = passes.size + 1

    /** Passes (final included) whose load exceeds the budget. */
    val overBudgetPasses: Int get() = passes.count { it.overBudget } + (if (finalOverBudget) 1 else 0)
}

/** Disk needs of a precomposed export (file header). */
data class DiskEstimate(
    /** One intermediate. */
    val intermediateBytes: Long,
    /** Intermediates alive at once (0, 1 or 2 of them). */
    val peakIntermediateBytes: Long,
    /** The export output (EncoderSettings.estimatedBytes). */
    val outputBytes: Long,
    /** Peak bytes on the work volume: intermediates alive together, or the last one plus the output. */
    val peakBytes: Long,
) {
    /** What the precompose adds on top of a single-pass export's own estimate. */
    val extraBytes: Long get() = peakBytes - outputBytes
}

/** The planner (file header). */
object PrecomposePlanner {
    /** How intermediates are encoded. */
    data class Options(
        /** Requested intermediate bitrate as a multiple of the export bitrate (D-45: ≥ 4×). */
        val bitrateFactor: Int = 4,
        /** I-frame interval 0: every intermediate frame is a key frame (D-45: all-intra). */
        val allIntra: Boolean = true,
        /** The YUV matrix intermediates are encoded with and signal (file header). */
        val color: IntermediateColor = IntermediateColor.BT601,
    ) {
        init {
            require(bitrateFactor >= 1) { "bitrateFactor" }
        }
    }

    /** The visual lanes of [spec], bottom → top (its LAYERS sequences, reversed). */
    fun lanes(spec: CompositionSpec): List<PlannerLane> = spec.layerSequences.asReversed().map { lane(spec, it) }

    private fun lane(spec: CompositionSpec, s: SequenceSpec): PlannerLane {
        if (s.slot == null) return PlannerLane(isSlot = false)
        // Slot lanes hold media layers only (VisualStacker); each active range is one layer.
        return PlannerLane(isSlot = true, media = s.active.map { MediaSpan(it.t0, it.t1) })
    }

    /** The decoder load of lanes `[from, to)`, plus one always-active slot when [readsIntermediate]. */
    fun load(lanes: List<PlannerLane>, from: Int, to: Int, readsIntermediate: Boolean): MultiPassRouting.Load {
        var slots = if (readsIntermediate) 1 else 0
        val edges = ArrayList<Pair<Long, Int>>()
        for (i in from until to) {
            val l = lanes[i]
            if (!l.isSlot) continue
            slots++
            for (m in l.media) {
                edges += m.t0 to 1
                edges += m.t1 to -1
            }
        }
        edges.sortWith(compareBy<Pair<Long, Int>> { it.first }.thenBy { it.second })
        var current = 0
        var peak = 0
        for ((_, d) in edges) {
            current += d
            peak = maxOf(peak, current)
        }
        return MultiPassRouting.Load(slots, peak + if (readsIntermediate) 1 else 0)
    }

    /** Whether [load] fits [budget] (a budget below one slot is treated as one). */
    fun fits(load: MultiPassRouting.Load, budget: DecoderBudget): Boolean =
        load.slots <= maxOf(1, budget.maxVisualSequences) && load.peakDecoders <= maxOf(1, budget.maxDecoders)

    /** The pass split of [lanes] under [budget] (file header). */
    fun plan(lanes: List<PlannerLane>, budget: DecoderBudget): PrecomposePlan {
        val passes = ArrayList<PassRange>()
        var start = 0
        var reads = false
        while (true) {
            val rest = load(lanes, start, lanes.size, reads)
            val firstSlot = (start until lanes.size).firstOrNull { lanes[it].isSlot }
            if (fits(rest, budget) || firstSlot == null) {
                return PrecomposePlan(passes, start, lanes.size, rest, !fits(rest, budget))
            }
            var cut = -1
            for (i in firstSlot until lanes.size) {
                if (!lanes[i].isSlot) continue
                if (fits(load(lanes, start, i + 1, reads), budget)) cut = i + 1 else break
            }
            val forced = cut < 0
            if (forced) cut = firstSlot + 1
            val l = load(lanes, start, cut, reads)
            passes += PassRange(passes.size + 1, start, cut, reads, l, forced)
            start = cut
            reads = true
        }
    }

    /** Intermediate encoder settings of an export with [export] settings (file header). */
    fun intermediateSettings(export: EncoderSettings, options: Options = Options()): EncoderSettings = export.copy(
        videoBitrate = minOf(Int.MAX_VALUE.toLong(), export.videoBitrate.toLong() * options.bitrateFactor).toInt(),
        keyframeIntervalMs = if (options.allIntra) 0 else export.keyframeIntervalMs,
    )

    /** The plan duration plus one grid frame (intermediates are rendered over it, file header). */
    fun paddedDurationUs(plan: RenderPlan): Long {
        val grid = FrameGrid.of(plan.canvas.gridFps)
        return grid.timeOfFrame(grid.frameIndexOf(plan.durUs) + 1)
    }

    /** Bytes of one video-only intermediate of [durUs] at [settings]: bitrate · seconds / 8 · 1.02. */
    fun intermediateBytes(settings: EncoderSettings, durUs: Long): Long = (settings.videoBitrate.toLong() * durUs / 8_000_000.0 * 1.02).toLong()

    /** Disk needs of the [split] of [renderPlan] exported with [export] settings (file header). */
    fun diskEstimate(split: PrecomposePlan, export: EncoderSettings, renderPlan: RenderPlan, options: Options = Options()): DiskEstimate {
        val output = export.estimatedBytes(renderPlan.durUs)
        val n = split.intermediateCount
        if (n == 0) return DiskEstimate(0, 0, output, output)
        val one = intermediateBytes(intermediateSettings(export, options), paddedDurationUs(renderPlan))
        val alive = minOf(n, 2) * one
        return DiskEstimate(one, alive, output, maxOf(alive, one + output))
    }

    /** Relative cost of each pass (intermediates first, final last), file header. */
    fun passWeights(plan: PrecomposePlan): DoubleArray {
        val w = DoubleArray(plan.totalPasses)
        for ((i, p) in plan.passes.withIndex()) w[i] = (p.to - p.from + 1 + (if (p.readsIntermediate) 1 else 0)).toDouble()
        val finalLanes = plan.laneCount - plan.finalFrom
        w[w.size - 1] = finalLanes + 1.0 + (if (plan.passes.isEmpty()) 0.0 else 1.0) + 0.5
        return w
    }
}
