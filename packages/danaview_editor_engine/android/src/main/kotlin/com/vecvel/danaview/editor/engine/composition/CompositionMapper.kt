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
// Past the source end (ARCH §11.5: the displayed frame is the greatest PTS <= s + 500 µs, so a
// layer whose map runs past its source shows the LAST source frame there, as AND-16's live decks
// do): a media item whose map needs more source than the clip start leaves is split on the grid at
// the first frame kH whose rule frame is the last one. [k0, kH) plays the source (SpeedFit on the
// map cut at kH); [kH, k1) is a `hold` MEDIA item of the last frame, which Media3Composition draws
// as a still image at the output fps (Media3Composition.FrameStills). Never a slowed clip: SpeedFit
// stretching the remaining source over the whole item showed other frames than live and export.
// Audio past its source end is silence (an AUDIO_GAP from the first grid frame whose source time
// reaches the source duration), as the live audio decks play it.

package com.vecvel.danaview.editor.engine.composition

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
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
            when (p.layer.kind) {
                PlanLayerKind.MEDIA -> items.addAll(mediaItems(p.layer, plan, a, options))
                PlanLayerKind.IMAGE -> items += generated(ItemKind.IMAGE, p.t0, p.t1, a, fps, p.layer.id, assetOf(plan, p.layer).uri)
                PlanLayerKind.SOLID -> items += generated(ItemKind.SOLID, p.t0, p.t1, a, fps, p.layer.id)
                PlanLayerKind.SPRITE -> items += generated(ItemKind.SPRITE, p.t0, p.t1, a, fps, p.layer.id)
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

    /**
     * The items of media layer [l]: one MEDIA item, or (its map running past the source end, file
     * header) the played part and a `hold` item of the last source frame.
     */
    private fun mediaItems(l: PlanLayer, plan: RenderPlan, a: Anchor, options: Options): List<ItemSpec> {
        val asset = assetOf(plan, l)
        val uri = if (options.useProxies && plan.target == PlanTarget.PREVIEW) asset.proxyUri ?: asset.uri else asset.uri
        val s0 = l.map.first().s0
        val start = a.at(l.t0)
        val end = a.at(l.t1)
        val k0 = a.frame(l.t0)
        val k1 = a.frame(l.t1)
        val (clipStart, sourceDur) = try {
            timeline.ruleFramePtsUs(uri, s0) to (timeline.durationUs(uri) ?: asset.durUs)
        } catch (e: IOException) {
            throw sourceFailure(e, l.id, asset)
        }
        val maxRate = l.map.maxOf { it.rate }
        fun held(from: Long, k: Long, framePts: Long) = ItemSpec(
            kind = ItemKind.MEDIA, startUs = from, endUs = end, k0 = k, k1 = k1,
            layerId = l.id, uri = uri, clipStartUs = framePts, clipEndUs = framePts,
            sourceDurationUs = sourceDur, planSourceStartUs = s0, hold = true, maxRate = maxRate,
        )
        if (l.hold) return listOf(held(start, k0, clipStart))
        val maxInput = sourceDur?.let { it - clipStart } ?: Long.MAX_VALUE
        if (sourceDur != null && l.map.last().s1 - clipStart > maxInput) {
            // The map runs past the source end: hold the last frame from the first grid frame whose
            // rule frame is the last one (ARCH §11.5; AND-16's decks show it there).
            val lastPts = try {
                timeline.ruleFramePtsUs(uri, sourceDur)
            } catch (e: IOException) {
                throw sourceFailure(e, l.id, asset)
            }
            val kH = firstHeldFrame(l.map, a.grid, k0, k1, lastPts)
            if (kH == k0) return listOf(held(start, k0, lastPts))
            if (kH < k1) {
                val tH = a.grid.timeOfFrame(kH)
                val played = cutMap(l.map, tH)
                val mid = a.at(tH)
                return listOf(
                    playedItem(l, uri, start, mid, k0, kH, clipStart, sourceDur, s0, played, maxInput, plan),
                    held(mid, kH, lastPts),
                )
            }
            // No grid frame reaches the last source frame (the map ends less than a frame past the
            // source): the clip below stays inside the source with a sub-frame speed fit.
        }
        return listOf(playedItem(l, uri, start, end, k0, k1, clipStart, sourceDur, s0, l.map, maxInput, plan))
    }

    private fun playedItem(
        l: PlanLayer,
        uri: String,
        start: Long,
        end: Long,
        k0: Long,
        k1: Long,
        clipStart: Long,
        sourceDur: Long?,
        s0: Long,
        map: List<MapSegment>,
        maxInput: Long,
        plan: RenderPlan,
    ): ItemSpec {
        val maxRate = l.map.maxOf { it.rate }
        val fit = SpeedFit.fit(map, end - start, maxInput)
        return ItemSpec(
            kind = ItemKind.MEDIA,
            startUs = start,
            endUs = end,
            k0 = k0,
            k1 = k1,
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
            val maxInput = sourceDur?.let { it - clipStart } ?: Long.MAX_VALUE
            val k0 = a.frame(s.t0)
            val k1 = a.frame(s.t1)
            var map = s.map
            var kEnd = k1
            var playedEnd = end
            if (sourceDur != null && s.map.last().s1 - clipStart > maxInput) {
                // Past the source end the segment is silent (file header): it plays at its rate up
                // to the last grid frame whose source time is still inside the source (so the clip
                // never needs a speed fit past the end), then a gap.
                kEnd = (firstFrameAtOrPast(s.map, a.grid, k0, k1, sourceDur + 1) - 1).coerceAtLeast(k0)
                val tEnd = a.grid.timeOfFrame(kEnd)
                playedEnd = a.at(tEnd)
                if (kEnd > k0) map = cutMap(s.map, tEnd)
            }
            if (playedEnd <= start) {
                items += ItemSpec(ItemKind.AUDIO_GAP, start, end, k0, k1)
                cursor = s.t1
                continue
            }
            val fit = SpeedFit.fit(map, playedEnd - start, maxInput)
            items += ItemSpec(
                kind = ItemKind.AUDIO,
                startUs = start,
                endUs = playedEnd,
                k0 = k0,
                k1 = kEnd,
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
            if (playedEnd < end) items += ItemSpec(ItemKind.AUDIO_GAP, playedEnd, end, kEnd, k1)
            cursor = s.t1
        }
        if (cursor < plan.durUs) items += ItemSpec(ItemKind.AUDIO_GAP, a.at(cursor), plan.durUs, a.frame(cursor), a.frame(plan.durUs))
        return SequenceSpec(index = index, kind = SequenceKind.AUDIO, trackTypes = TrackTypes.AUDIO, items = items)
    }

    companion object {
        /**
         * Source time (µs) of [map] at plan time [t]: `s0 + (t − t0)·rate` on the segment holding
         * [t] (clamped to the map), floored to µs. The same evaluation as the live path
         * (PausedFrames.sourceTimeUs, AND-16's decks) so both pick the same frames.
         */
        fun sourceTimeUs(map: List<MapSegment>, t: Long): Long {
            val seg = map.firstOrNull { t >= it.t0 && t < it.t1 } ?: if (t < map[0].t0) map[0] else map[map.size - 1]
            if (seg.t1 <= seg.t0) return seg.s0
            val tc = t.coerceIn(seg.t0, seg.t1)
            return Math.floor(seg.sourceAt(tc.toDouble()) + 1e-6).toLong().coerceAtLeast(0L)
        }

        /**
         * The first grid frame k in [k0, k1) whose rule frame is [lastPts] (source time + ε reaches
         * it), or [k1] when none. Source time increases with k (rates are positive).
         */
        fun firstHeldFrame(map: List<MapSegment>, grid: FrameGrid, k0: Long, k1: Long, lastPts: Long): Long =
            firstFrameAtOrPast(map, grid, k0, k1, lastPts - SourceTimeline.EPSILON_US)

        /** The first grid frame k in [k0, k1) whose source time is >= [sourceUs], or [k1] when none. */
        fun firstFrameAtOrPast(map: List<MapSegment>, grid: FrameGrid, k0: Long, k1: Long, sourceUs: Long): Long {
            var lo = k0
            var hi = k1
            while (lo < hi) {
                val mid = lo + (hi - lo) / 2
                if (sourceTimeUs(map, grid.timeOfFrame(mid)) >= sourceUs) hi = mid else lo = mid + 1
            }
            return lo
        }

        /** [map] up to plan time [tEnd] (on the grid, inside the map): the segment holding it is cut there. */
        fun cutMap(map: List<MapSegment>, tEnd: Long): List<MapSegment> = map.filter { it.t0 < tEnd }.map { seg ->
            if (seg.t1 <= tEnd) {
                seg
            } else {
                val s1 = seg.s0 + Math.round((tEnd - seg.t0).toDouble() * (seg.s1 - seg.s0).toDouble() / (seg.t1 - seg.t0).toDouble())
                MapSegment(seg.t0, tEnd, seg.s0, s1)
            }
        }
    }
}
