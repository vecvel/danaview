// OWNER: AND-08
//
// Plan → composition mapping (ARCH §13.3 "Sequence stack", "Items", "Compositing"; §11 overrides
// native.md §4.2: the plan is a flat, fully lowered layer list). Pure: it reads source timing
// through [SourceTimeline] and produces a [CompositionSpec]; Media3Composition builds the
// Transformer `Composition` from it (export, AND-11) and AND-16's slot decks play its LAYERS and
// AUDIO sequences (AND-01: CompositionPlayer is not the preview engine).
//
// Sequence stack (index 0 = top = frame clock):
//   0      transparent 2×2 clock band image at the output fps, trackTypes {VIDEO, AUDIO} (D-38:
//          every composition has video frames exactly on the output grid AND an audio track);
//   1..n   layer sequences top → bottom: one per packing slot `seq` (as the compiler assigned it,
//          CORE-36) plus the non-media layers stacked between them (VisualStack), trackTypes
//          {VIDEO}, padded to durUs with transparent canvas images at the output fps (never
//          `addGap`, AND-01 V-N18/V-N25);
//   n+1    opaque background at the output fps;
//   n+2…   audio-only sequences, one per audio interval colour, trackTypes {AUDIO}.
// Timing (ARCH §5 rule 3, D-35): every item and gap boundary sits exactly on P(k) =
// round(k·1e6/gridFps) of its grid frame k (durations are differences of P); the end of every
// sequence is the plan's durUs. Media items: clip start = PTS of the rule frame of map[0].s0
// (AND-01 SNAP_TO_RULE_FRAME); the clip end is fitted so the item's Media3 duration is exactly its
// P-anchored duration (SpeedFit: ≤ a few µs × rate); a piecewise speed provider for rate ≠ 1;
// `setFrameRate(gridFps)` when faster than 1× (V-N17); `setDurationUs` = the full source duration
// (AND-01 §6.7); video items drop their audio, audio items their video. Gating (which layer of a
// sequence covers an output frame) is LayerGating's, on the spec's active ranges.

package com.vecvel.vwish.editor.engine.composition

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.plan.AudioSeg
import com.vecvel.vwish.editor.engine.plan.FrameGrid
import com.vecvel.vwish.editor.engine.plan.PlanAsset
import com.vecvel.vwish.editor.engine.plan.PlanLayer
import com.vecvel.vwish.editor.engine.plan.PlanLayerKind
import com.vecvel.vwish.editor.engine.plan.PlanTarget
import com.vecvel.vwish.editor.engine.plan.PlanValidator
import com.vecvel.vwish.editor.engine.plan.RenderPlan
import java.io.IOException

/** Maps validated plans to [CompositionSpec]s (file header). */
class CompositionMapper(private val timeline: SourceTimeline) {
    /** Mapping options. */
    data class Options(
        /** Use `proxyUri` for video layers when present (preview only; same timestamps). */
        val useProxies: Boolean = false,
        /** Validate the plan first (ARCH §11.3); a violation is `planInvalid`. */
        val validate: Boolean = true,
    )

    /** Maps [plan]; throws [EngineException] (`planInvalid`, or the source failure) on error. */
    fun map(plan: RenderPlan, options: Options = Options()): CompositionSpec {
        if (options.validate) {
            val violations = PlanValidator.validate(plan)
            if (violations.isNotEmpty()) {
                val v = violations.first()
                throw EngineException(EngineErrorCode.planInvalid, "plan violates ${v.code.name}", itemId = v.id)
            }
        }
        val canvas = plan.canvas
        val grid = FrameGrid.of(canvas.gridFps)
        val durUs = plan.durUs
        val anchor = Anchor(grid, durUs)
        val sequences = ArrayList<SequenceSpec>()

        // 0: clock band.
        sequences += SequenceSpec(
            index = 0,
            kind = SequenceKind.CLOCK_BAND,
            trackTypes = TrackTypes.VIDEO_AND_AUDIO,
            items = if (durUs > 0) listOf(generated(ItemKind.CLOCK, 0L, durUs, anchor, canvas.fps)) else emptyList(),
        )

        // 1..n: layer sequences, top → bottom.
        val stack = VisualStacker.stack(plan.layers)
        for (lane in stack.lanes.asReversed()) {
            sequences += layerSequence(sequences.size, lane, plan, anchor, options)
        }

        // n+1: background.
        sequences += SequenceSpec(
            index = sequences.size,
            kind = SequenceKind.BACKGROUND,
            trackTypes = TrackTypes.VIDEO,
            items = if (durUs > 0) listOf(generated(ItemKind.BACKGROUND, 0L, durUs, anchor, canvas.fps)) else emptyList(),
        )

        // n+2…: audio interval colours.
        for (lane in audioLanes(plan.audio)) {
            sequences += audioSequence(sequences.size, lane, plan, anchor)
        }

        return CompositionSpec(
            canvasW = canvas.w,
            canvasH = canvas.h,
            outputFps = canvas.fps,
            gridFps = canvas.gridFps,
            durUs = durUs,
            bg = canvas.bg,
            sequences = sequences,
            layers = plan.layers.associateBy { it.id },
        )
    }

    /** Plan time → composition time: P(k) of the grid frame, the plan end at durUs. */
    private class Anchor(val grid: FrameGrid, val durUs: Long) {
        fun frame(t: Long): Long = grid.frameIndexOf(t)

        fun at(t: Long): Long = if (t >= durUs) durUs else grid.platformTimeOfFrame(grid.frameIndexOf(t))
    }

    private fun generated(kind: ItemKind, t0: Long, t1: Long, a: Anchor, fps: Int, layerId: String? = null, uri: String? = null) =
        ItemSpec(kind = kind, startUs = a.at(t0), endUs = a.at(t1), k0 = a.frame(t0), k1 = a.frame(t1), layerId = layerId, uri = uri, frameRate = fps)

    private fun layerSequence(index: Int, lane: StackLane, plan: RenderPlan, a: Anchor, options: Options): SequenceSpec {
        val fps = plan.canvas.fps
        val items = ArrayList<ItemSpec>()
        val active = ArrayList<ActiveRange>()
        var cursor = 0L
        for (p in lane.pieces) {
            if (p.t0 > cursor) items += generated(ItemKind.GAP, cursor, p.t0, a, fps)
            items += when (p.layer.kind) {
                PlanLayerKind.MEDIA -> mediaItem(p.layer, plan, a, options)
                PlanLayerKind.IMAGE -> generated(ItemKind.IMAGE, p.t0, p.t1, a, fps, p.layer.id, assetOf(plan, p.layer).uri)
                PlanLayerKind.SOLID -> generated(ItemKind.SOLID, p.t0, p.t1, a, fps, p.layer.id)
                PlanLayerKind.SPRITE -> generated(ItemKind.SPRITE, p.t0, p.t1, a, fps, p.layer.id)
            }
            active += ActiveRange(p.t0, p.t1, p.layer.id)
            cursor = p.t1
        }
        if (cursor < plan.durUs) items += generated(ItemKind.GAP, cursor, plan.durUs, a, fps)
        return SequenceSpec(
            index = index,
            kind = SequenceKind.LAYERS,
            trackTypes = TrackTypes.VIDEO,
            items = items,
            active = active,
            slot = lane.slot,
            layerKinds = lane.pieces.map { it.layer.kind }.toSet(),
        )
    }

    private fun assetOf(plan: RenderPlan, layer: PlanLayer): PlanAsset =
        layer.asset?.let { plan.assets[it] } ?: throw EngineErrors.invalidPlan("layer without its asset")

    private fun sourceFailure(e: IOException, itemId: String, asset: PlanAsset): EngineException {
        val base = EngineErrors.from(e)
        val code = if (base.code == EngineErrorCode.io) EngineErrorCode.mediaOffline else base.code
        return EngineException(code, "source unreadable", itemId = itemId, mediaFingerprint = asset.fp.ifEmpty { null }, cause = e)
    }

    private fun mediaItem(l: PlanLayer, plan: RenderPlan, a: Anchor, options: Options): ItemSpec {
        val asset = assetOf(plan, l)
        val uri = if (options.useProxies && plan.target == PlanTarget.PREVIEW) asset.proxyUri ?: asset.uri else asset.uri
        val s0 = l.map.first().s0
        val start = a.at(l.t0)
        val end = a.at(l.t1)
        val (clipStart, sourceDur) = try {
            timeline.ruleFramePtsUs(uri, s0) to (timeline.durationUs(uri) ?: asset.durUs)
        } catch (e: IOException) {
            throw sourceFailure(e, l.id, asset)
        }
        val maxRate = l.map.maxOf { it.rate }
        if (l.hold) {
            return ItemSpec(
                kind = ItemKind.MEDIA, startUs = start, endUs = end, k0 = a.frame(l.t0), k1 = a.frame(l.t1),
                layerId = l.id, uri = uri, clipStartUs = clipStart, clipEndUs = clipStart,
                sourceDurationUs = sourceDur, planSourceStartUs = s0, hold = true, maxRate = maxRate,
            )
        }
        val maxInput = sourceDur?.let { it - clipStart } ?: Long.MAX_VALUE
        val fit = SpeedFit.fit(l.map, end - start, maxInput)
        return ItemSpec(
            kind = ItemKind.MEDIA,
            startUs = start,
            endUs = end,
            k0 = a.frame(l.t0),
            k1 = a.frame(l.t1),
            layerId = l.id,
            uri = uri,
            clipStartUs = clipStart,
            clipEndUs = clipStart + fit.inputDurationUs,
            sourceDurationUs = sourceDur,
            planSourceStartUs = s0,
            speed = fit.provider,
            keepPitch = true,
            frameRate = if (maxRate > 1.0) plan.canvas.gridFps else null,
            maxRate = maxRate,
        )
    }

    /** Greedy interval colouring of the audio segments in (t0, id) order. */
    private fun audioLanes(audio: List<AudioSeg>): List<List<AudioSeg>> {
        val lanes = ArrayList<MutableList<AudioSeg>>()
        val ends = ArrayList<Long>()
        for (s in audio.sortedWith(PlanValidator::compareAudio)) {
            val i = ends.indexOfFirst { it <= s.t0 }
            if (i < 0) {
                lanes += mutableListOf(s)
                ends += s.t1
            } else {
                lanes[i] += s
                ends[i] = s.t1
            }
        }
        return lanes
    }

    private fun audioSequence(index: Int, lane: List<AudioSeg>, plan: RenderPlan, a: Anchor): SequenceSpec {
        val items = ArrayList<ItemSpec>()
        var cursor = 0L
        for (s in lane) {
            if (s.t0 > cursor) {
                items += ItemSpec(ItemKind.AUDIO_GAP, a.at(cursor), a.at(s.t0), a.frame(cursor), a.frame(s.t0))
            }
            val asset = plan.assets[s.asset] ?: throw EngineErrors.invalidPlan("audio segment without its asset")
            val start = a.at(s.t0)
            val end = a.at(s.t1)
            val clipStart = s.map.first().s0
            val sourceDur = try {
                timeline.durationUs(asset.uri) ?: asset.durUs
            } catch (e: IOException) {
                throw sourceFailure(e, s.id, asset)
            }
            val fit = SpeedFit.fit(s.map, end - start, sourceDur?.let { it - clipStart } ?: Long.MAX_VALUE)
            items += ItemSpec(
                kind = ItemKind.AUDIO,
                startUs = start,
                endUs = end,
                k0 = a.frame(s.t0),
                k1 = a.frame(s.t1),
                segmentId = s.id,
                uri = asset.uri,
                clipStartUs = clipStart,
                clipEndUs = clipStart + fit.inputDurationUs,
                sourceDurationUs = sourceDur,
                planSourceStartUs = clipStart,
                speed = fit.provider,
                keepPitch = s.pitch,
                stream = s.stream,
                gain = s.gain,
                maxRate = fit.maxRate,
            )
            cursor = s.t1
        }
        if (cursor < plan.durUs) items += ItemSpec(ItemKind.AUDIO_GAP, a.at(cursor), plan.durUs, a.frame(cursor), a.frame(plan.durUs))
        return SequenceSpec(index = index, kind = SequenceKind.AUDIO, trackTypes = TrackTypes.AUDIO, items = items)
    }
}
