// OWNER: AND-16
//
// The contingency engine's plan of decks (ARCH §13.3 "Decks", §13.5; AND-01.md §2, §7). Pure: no
// Android or Media3 types, so it is exercised the same way on any runtime.
//
// - Video: one [SlotSpec] per packing slot `seq` (CORE-36, the compiler's assignment; engines use it
//   as-is). Its media layers become one clipped playlist ([DeckItem]s in time order) played by two
//   decks. Clip starts snap to the rule frame of the layer's first source time (ARCH §11.5,
//   SNAP_TO_RULE_FRAME, AND-01 V-N16). `hold` layers (pending freeze stills) never decode: they are
//   still layers.
// - Live decode budget (owner decision D-43(e), D-45): the [liveBudget] lowest slots (the main track
//   sits in the lowest slot) get decks; every other slot is a still slot whose layers play as
//   paused-exact stills during playback only (paused, scrub and exact seek fetch the exact frame of
//   every layer). maxVisualSequences limits live preview only.
// - Audio: one [AudioLaneSpec] per interval colour (AND-08's greedy colouring in (t0, id) order),
//   coloured separately per source audio stream so a lane's players select one stream.
// - Structural re-plan by slot diff: [changedSlots] / [changedLanes] compare the item keys, so a
//   rebuild calls `setMediaItems` on the affected decks only.
// Time rule (ARCH §5, D-35): items are active over the plan range [t0, t1); an output frame k is
// evaluated at timeOfFrame(k) of the output grid.

package com.vecvel.danaview.editor.engine.preview.fallback

import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.PausedFrames
import com.vecvel.danaview.editor.engine.preview.SeekMath
import kotlin.math.floor

/** Rule-frame facts of a source (ARCH §11.5). Implementations may block (I/O); never called on danaview-gl per frame. */
interface RuleFrames {
    /** PTS (µs) of the rule frame of source time [sourceUs]: the greatest video sample PTS ≤ s + 500 µs (the first when none). */
    fun rule(uri: String, sourceUs: Long): Long

    /** The video sample PTS of [uri], ascending (the deck's frame times). */
    fun frameTimes(uri: String): LongArray

    /** The source's duration in µs, or null. */
    fun durationUs(uri: String): Long?
}

/** Rule-frame lookups over an ascending PTS table (shared by the index and tests). */
object RuleFrameMath {
    /** Rule-frame tolerance ε (ARCH §11.5, D-04). */
    const val EPSILON_US: Long = 500L

    /** The rule frame of [sourceUs] in [pts] (ascending): greatest PTS ≤ s + ε, else the first. */
    fun rule(pts: LongArray, sourceUs: Long): Long {
        require(pts.isNotEmpty()) { "no frames" }
        val target = sourceUs + EPSILON_US
        var lo = 0
        var hi = pts.size - 1
        if (pts[0] > target) return pts[0]
        while (lo < hi) {
            val mid = (lo + hi + 1) ushr 1
            if (pts[mid] <= target) lo = mid else hi = mid - 1
        }
        return pts[lo]
    }

    /** The PTS after [pts] of [table] (the next frame), or null at the end. */
    fun next(table: LongArray, pts: Long): Long? {
        var lo = 0
        var hi = table.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (table[mid] <= pts) lo = mid + 1 else hi = mid
        }
        return if (lo < table.size) table[lo] else null
    }
}

/**
 * One playlist item of a deck: a media layer (or, with [range], a rendered range of the
 * render-preview cache, D-45). [t0]..[t1] is its plan range; [clipStartUs]/[clipEndUs] its source
 * clip; [key] identifies it for the slot diff.
 */
class DeckItem(
    val key: String,
    val layer: PlanLayer?,
    val t0: Long,
    val t1: Long,
    val uri: String,
    val clipStartUs: Long,
    val clipEndUs: Long,
    /** Display rotation of the source (0, 90, 180, 270). */
    val rotation: Int,
    /** The rendered range this item plays (null for a layer). */
    val range: RenderedRange? = null,
) {
    /** Whether plan time [t] lies in the item. */
    fun covers(t: Long): Boolean = t >= t0 && t < t1

    /** Source time (µs) at plan time [t] (ARCH §11.5: map segment, floored). */
    fun sourceAt(t: Long, grid: FrameGrid): Long {
        val r = range
        if (r != null) return grid.platformTimeOfFrame(grid.frameIndexOf(t) - r.first)
        return PausedFrames.sourceTimeUs(requireNotNull(layer), t)
    }

    /** The plan speed at plan time [t] (1 for ranges). */
    fun speedAt(t: Long): Double {
        val l = layer ?: return 1.0
        val seg = l.map.firstOrNull { t >= it.t0 && t < it.t1 } ?: l.map.lastOrNull() ?: return 1.0
        return if (seg.t1 > seg.t0 && seg.rate > 0.0) seg.rate else 1.0
    }

    /** The item (window) position in ms at which rule frame [rulePtsUs] is the first frame ≥ it (V-N18: floor, ARCH §13.3). */
    fun positionMs(rulePtsUs: Long): Long = SeekMath.deckSeekMs(rulePtsUs.coerceAtLeast(clipStartUs), clipStartUs)
}

/** One packing slot: its items (time order) and whether it plays live. */
class SlotSpec(val seq: Int, val items: List<DeckItem>, val live: Boolean) {
    /** Index of the item active at plan time [t], or -1. */
    fun activeAt(t: Long): Int {
        var lo = 0
        var hi = items.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val it = items[mid]
            when {
                t < it.t0 -> hi = mid - 1
                t >= it.t1 -> lo = mid + 1
                else -> return mid
            }
        }
        return -1
    }

    /** Index of the first item starting after plan time [t], or -1. */
    fun nextAfter(t: Long): Int {
        for (i in items.indices) if (items[i].t0 > t) return i
        return -1
    }

    /** The item keys (slot diff). */
    val keys: List<String> get() = items.map { it.key }
}

/** One audio segment of a lane. */
class AudioItem(
    val key: String,
    val seg: AudioSeg,
    val uri: String,
    val clipStartUs: Long,
    val clipEndUs: Long,
) {
    val t0: Long get() = seg.t0
    val t1: Long get() = seg.t1

    /** Whether plan time [t] lies in the segment. */
    fun covers(t: Long): Boolean = t >= seg.t0 && t < seg.t1

    /** Source time at plan time [t] (map segment, floored). */
    fun sourceAt(t: Long): Long = SlotPlanner.sourceAt(seg.map, t)

    /** Plan speed at [t]. */
    fun speedAt(t: Long): Double {
        val s = seg.map.firstOrNull { t >= it.t0 && t < it.t1 } ?: seg.map.lastOrNull() ?: return 1.0
        return if (s.t1 > s.t0 && s.rate > 0.0) s.rate else 1.0
    }

    /** Plan time of source time [sourceUs] (inverse of the map; clamped to the segment). */
    fun planTimeOf(sourceUs: Long): Long = SlotPlanner.planTimeOf(seg.map, sourceUs).coerceIn(seg.t0, seg.t1)

    /** Window position (ms) of source time [sourceUs]. */
    fun positionMs(sourceUs: Long): Long = Math.floorDiv((sourceUs - clipStartUs).coerceAtLeast(0L), 1000L)

    /** The gain envelope (plan time). */
    val gain: Keyframes get() = seg.gain
}

/** One audio interval colour of one source stream. */
class AudioLaneSpec(val lane: Int, val stream: Int, val items: List<AudioItem>) {
    /** Index of the item active at plan time [t], or -1. */
    fun activeAt(t: Long): Int = items.indexOfFirst { it.covers(t) }

    /** Index of the first item starting after [t], or -1. */
    fun nextAfter(t: Long): Int = items.indexOfFirst { it.t0 > t }

    val keys: List<String> get() = items.map { it.key }
}

/** The decks of one plan (file header). */
class SlotPlan(
    val rev: Long,
    val fps: Int,
    val durUs: Long,
    val slots: List<SlotSpec>,
    val audio: List<AudioLaneSpec>,
    /** Media layers drawn from stills during playback (over the live budget, or `hold`). */
    val stillLayers: Set<String>,
    /** Every media layer id with its slot. */
    val layerSlot: Map<String, Int>,
    /** Media layers whose source could not be read (offline, no video track): drawn without them. */
    val unavailable: Set<String> = emptySet(),
) {
    /** The output grid. */
    val grid: FrameGrid get() = FrameGrid.of(fps)

    /** The slot of [seq], or null. */
    fun slot(seq: Int): SlotSpec? = slots.firstOrNull { it.seq == seq }

    companion object {
        /** A plan with nothing to play. */
        fun empty(fps: Int): SlotPlan = SlotPlan(0, fps, 0, emptyList(), emptyList(), emptySet(), emptyMap())
    }
}

/** Builds and diffs [SlotPlan]s (file header). */
object SlotPlanner {
    /** Source past the last frame kept in a clip (the gating stops showing it anyway). */
    const val CLIP_TAIL_US: Long = 100_000L

    /** Live decode slots per tier (AND-01 §7 bullet 1, D-43(e)): minimal/low 2, mid 4, high 6. */
    fun tierBudget(tier: DeviceTierMsg): Int = when (tier) {
        DeviceTierMsg.MINIMAL, DeviceTierMsg.LOW -> 2
        DeviceTierMsg.MID -> 4
        DeviceTierMsg.HIGH -> 6
    }

    /** The live budget: the tier's slots, capped by the device's `maxVisualSequences` (>= 1). */
    fun liveBudget(tier: DeviceTierMsg, maxVisualSequences: Long?): Int {
        val t = tierBudget(tier)
        val cap = maxVisualSequences?.takeIf { it > 0 }?.toInt() ?: t
        return minOf(t, cap).coerceAtLeast(1)
    }

    /**
     * The slot plan of [plan]. [useProxies] plays proxies where assets have them; [liveBudget]
     * slots play live; [rules] answers rule frames (blocking; call off danaview-gl).
     */
    fun plan(plan: RenderPlan, rules: RuleFrames, useProxies: Boolean, liveBudget: Int): SlotPlan {
        val grid = FrameGrid.of(plan.canvas.fps)
        val media = plan.layers.filter { it.kind == PlanLayerKind.MEDIA && it.seq != null }
        val seqs = media.mapNotNull { it.seq }.distinct().sorted()
        val live = seqs.take(liveBudget.coerceAtLeast(0)).toSet()
        val stills = HashSet<String>()
        val unavailable = HashSet<String>()
        val layerSlot = HashMap<String, Int>()
        val slots = ArrayList<SlotSpec>()
        for (seq in seqs) {
            val items = ArrayList<DeckItem>()
            for (l in media.filter { it.seq == seq }.sortedWith(compareBy<PlanLayer> { it.t0 }.thenBy { it.id })) {
                layerSlot[l.id] = seq
                if (l.hold || l.map.isEmpty() || seq !in live) {
                    stills += l.id
                    continue
                }
                val asset = l.asset?.let { plan.assets[it] } ?: continue
                if (asset.kind != PlanAssetKind.VIDEO) continue
                val uri = if (useProxies && plan.target == PlanTarget.PREVIEW) asset.proxyUri ?: asset.uri else asset.uri
                val s0 = l.map.first().s0
                val (clipStart, duration) = try {
                    rules.rule(uri, s0) to rules.durationUs(uri)
                } catch (e: Exception) {
                    // Offline or unreadable: the preview draws without it (the export reports it).
                    unavailable += l.id
                    continue
                }
                val lastT = grid.timeOfFrame((grid.frameIndexOf(l.t1 - 1)).coerceAtLeast(grid.frameIndexOf(l.t0)))
                val sLast = PausedFrames.sourceTimeUs(l, lastT.coerceIn(l.t0, l.t1 - 1))
                var clipEnd = maxOf(sLast, s0) + CLIP_TAIL_US
                if (duration != null && duration > clipStart) clipEnd = minOf(clipEnd, duration)
                items += DeckItem(
                    key = layerKey(l, uri),
                    layer = l,
                    t0 = l.t0,
                    t1 = l.t1,
                    uri = uri,
                    clipStartUs = clipStart,
                    clipEndUs = maxOf(clipEnd, clipStart + 1),
                    rotation = normalizeRotation(asset.rot ?: 0),
                )
            }
            slots += SlotSpec(seq, items, seq in live)
        }
        return SlotPlan(plan.rev, plan.canvas.fps, plan.durUs, slots, audioLanes(plan, rules), stills, layerSlot, unavailable)
    }

    /** Diff identity of a layer item: the fields that change what the deck decodes. */
    fun layerKey(l: PlanLayer, uri: String): String = "${l.id}|${l.t0}|${l.t1}|${l.map}|${l.hold}|$uri"

    /** Seqs whose items differ between [old] and [new] (added, removed or changed slots). */
    fun changedSlots(old: SlotPlan?, new: SlotPlan): Set<Int> {
        if (old == null) return new.slots.map { it.seq }.toSet()
        val out = HashSet<Int>()
        val oldBy = old.slots.associateBy { it.seq }
        val newBy = new.slots.associateBy { it.seq }
        for ((seq, s) in newBy) {
            val o = oldBy[seq]
            if (o == null || o.keys != s.keys || o.live != s.live) out += seq
        }
        for (seq in oldBy.keys) if (seq !in newBy) out += seq
        return out
    }

    /** Audio lanes whose items differ (by lane index). */
    fun changedLanes(old: SlotPlan?, new: SlotPlan): Set<Int> {
        if (old == null) return new.audio.map { it.lane }.toSet()
        val out = HashSet<Int>()
        val n = maxOf(old.audio.size, new.audio.size)
        for (i in 0 until n) {
            val a = old.audio.getOrNull(i)
            val b = new.audio.getOrNull(i)
            if (a == null || b == null || a.keys != b.keys || a.stream != b.stream) out += i
        }
        return out
    }

    /** Greedy interval colouring per stream in (t0, id) order (AND-08's order). */
    fun audioLanes(plan: RenderPlan, rules: RuleFrames?): List<AudioLaneSpec> {
        val out = ArrayList<AudioLaneSpec>()
        val byStream = plan.audio.groupBy { it.stream }.toSortedMap()
        for ((stream, segs) in byStream) {
            val lanes = ArrayList<MutableList<AudioSeg>>()
            val ends = ArrayList<Long>()
            for (s in segs.sortedWith(PlanValidator::compareAudio)) {
                if (s.map.isEmpty() || s.t1 <= s.t0) continue
                val i = ends.indexOfFirst { it <= s.t0 }
                if (i < 0) {
                    lanes += mutableListOf(s)
                    ends += s.t1
                } else {
                    lanes[i] += s
                    ends[i] = s.t1
                }
            }
            for (lane in lanes) {
                val items = lane.mapNotNull { s ->
                    val asset = plan.assets[s.asset] ?: return@mapNotNull null
                    val start = s.map.first().s0
                    val endSrc = sourceAt(s.map, s.t1 - 1) + CLIP_TAIL_US
                    val dur = try {
                        rules?.durationUs(asset.uri)
                    } catch (e: Exception) {
                        return@mapNotNull null
                    }
                    val end = if (dur != null && dur > start) minOf(endSrc, dur) else endSrc
                    AudioItem("${s.id}|${s.t0}|${s.t1}|${s.map}|${s.stream}|${asset.uri}", s, asset.uri, start, maxOf(end, start + 1))
                }
                if (items.isNotEmpty()) out += AudioLaneSpec(out.size, stream, items)
            }
        }
        return out
    }

    /** Source time on [map] at plan time [t] (segment containing t, clamped; floored µs). */
    fun sourceAt(map: List<MapSegment>, t: Long): Long {
        require(map.isNotEmpty()) { "empty map" }
        val seg = map.firstOrNull { t >= it.t0 && t < it.t1 } ?: if (t < map[0].t0) map[0] else map[map.size - 1]
        if (seg.t1 <= seg.t0) return seg.s0
        val tc = t.coerceIn(seg.t0, seg.t1)
        return floor(seg.sourceAt(tc.toDouble()) + 1e-6).toLong().coerceAtLeast(0L)
    }

    /** Plan time of source time [s] on [map] (first segment whose source range holds it; else the nearest edge). */
    fun planTimeOf(map: List<MapSegment>, s: Long): Long {
        require(map.isNotEmpty()) { "empty map" }
        for (seg in map) {
            val lo = minOf(seg.s0, seg.s1)
            val hi = maxOf(seg.s0, seg.s1)
            if (s in lo..hi && seg.s1 != seg.s0) {
                return seg.t0 + ((s - seg.s0).toDouble() * (seg.t1 - seg.t0) / (seg.s1 - seg.s0)).toLong()
            }
        }
        return if (s < map[0].s0) map[0].t0 else map[map.size - 1].t1
    }

    /** 0, 90, 180 or 270. */
    fun normalizeRotation(rot: Int): Int = Math.floorMod(rot, 360).let { (it + 45) / 90 * 90 % 360 }
}
