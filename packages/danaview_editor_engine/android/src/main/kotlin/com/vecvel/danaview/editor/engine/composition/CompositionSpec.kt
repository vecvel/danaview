// OWNER: AND-08
//
// The engine-neutral result of mapping a plan (ARCH §13.3 "Sequence stack", "Items"): every
// sequence with its items, each item's composition range on the platform frame times P(k), its
// clipping, speed, frame-rate cap and gain. CompositionMapper builds it without touching Media3, so
// the mapping is unit-tested on the JVM; Media3Composition turns it into a Transformer
// `Composition` (AND-11 export) and AND-16's slot decks build their ExoPlayer playlists from the
// same LAYERS sequences and AUDIO lanes (AND-01: CompositionPlayer is not the preview engine).

package com.vecvel.danaview.editor.engine.composition

import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind

/** What a sequence carries (index order: clock band, layers top → bottom, background, audio). */
enum class SequenceKind {
    /** Index 0, the top: a transparent image at the output fps with trackTypes {VIDEO, AUDIO}. */
    CLOCK_BAND,

    /** One packing slot `seq` of media layers, or a sequence of non-media visual layers. */
    LAYERS,

    /** The opaque background solid. */
    BACKGROUND,

    /** One audio interval colour (audio-only). */
    AUDIO,
}

/** Track types of a sequence (Media3 `EditedMediaItemSequence.Builder(trackTypes)`). */
enum class TrackTypes { VIDEO, AUDIO, VIDEO_AND_AUDIO }

/** What an item is. */
enum class ItemKind {
    /** A clipped video source (media layer). */
    MEDIA,

    /** An image layer (decoded image at the output fps). */
    IMAGE,

    /** A solid layer: a small opaque white image; LayerPlaceEffect paints the plan colour. */
    SOLID,

    /** A sprite layer (export): a transparent canvas image the sprite effect draws on. */
    SPRITE,

    /** Transparent canvas-size image filling a layer sequence between layers (never `addGap`). */
    GAP,

    /** The 2×2 transparent clock band image. */
    CLOCK,

    /** The canvas-size background image. */
    BACKGROUND,

    /** A clipped audio source. */
    AUDIO,

    /** Silence in an audio sequence (`addGap`). */
    AUDIO_GAP,
}

/**
 * One item. [startUs] / [endUs] are its composition range (cumulative; every interior boundary is
 * a P(k) of the grid, the sequence end is the plan's `durUs`); [k0] / [k1] are the same edges as
 * gridFps frame indices. Source fields are set for MEDIA and AUDIO items only.
 */
data class ItemSpec(
    val kind: ItemKind,
    val startUs: Long,
    val endUs: Long,
    val k0: Long,
    val k1: Long,
    /** The plan layer (visual items) or null. */
    val layerId: String? = null,
    /** The audio segment id (AUDIO items) or null. */
    val segmentId: String? = null,
    /** Source URI (`file://` or `content://`), or null for generated images. */
    val uri: String? = null,
    /** Clip start in source µs (the rule-frame PTS for MEDIA, AND-01 V-N16; exact s0 for AUDIO). */
    val clipStartUs: Long = 0L,
    /** Clip end in source µs. */
    val clipEndUs: Long = 0L,
    /** Full source duration (`EditedMediaItem.setDurationUs`, AND-01 §6.7), or null if unknown. */
    val sourceDurationUs: Long? = null,
    /** The plan map's first source time (MEDIA/AUDIO). */
    val planSourceStartUs: Long = 0L,
    /** Speed over clip-relative input time, or null at constant 1×. */
    val speed: SegmentSpeedProvider? = null,
    /** Keep pitch when the speed ≠ 1 (audio `pitch`; true for video). */
    val keepPitch: Boolean = true,
    /** `EditedMediaItem.setFrameRate`: the output fps for images, gridFps for items faster than 1× (V-N17). */
    val frameRate: Int? = null,
    /** MEDIA `hold` (pending freeze still; preview only, export plans never hold). */
    val hold: Boolean = false,
    /** AUDIO: source audio stream index (ARCH §11.2 `stream`). */
    val stream: Int = 0,
    /** AUDIO: the gain envelope. */
    val gain: Keyframes? = null,
    /** Fastest plan rate of the item's map (MEDIA/AUDIO). */
    val maxRate: Double = 1.0,
) {
    /** Output duration in µs. */
    val durationUs: Long get() = endUs - startUs
}

/** A half-open plan-time range `[t0, t1)` of one layer (or layer piece) inside a sequence. */
data class ActiveRange(val t0: Long, val t1: Long, val layerId: String)

/** One sequence. */
data class SequenceSpec(
    /** Media3 sequence index (= compositor input id, AND-01 V-N1). */
    val index: Int,
    val kind: SequenceKind,
    val trackTypes: TrackTypes,
    val items: List<ItemSpec>,
    /** LAYERS: the plan-time ranges of its layers, sorted; the gating source of truth. */
    val active: List<ActiveRange> = emptyList(),
    /** LAYERS from a packing slot: the plan `seq`; null for non-media layer sequences. */
    val slot: Int? = null,
    /** LAYERS: the layer kinds it holds. */
    val layerKinds: Set<PlanLayerKind> = emptySet(),
) {
    /** Total duration in µs. */
    val durationUs: Long get() = items.lastOrNull()?.endUs ?: 0L

    /** The active range covering plan time [t], or null (binary search; ranges never overlap). */
    fun activeAt(t: Long): ActiveRange? {
        var lo = 0
        var hi = active.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val r = active[mid]
            when {
                t < r.t0 -> hi = mid - 1
                t >= r.t1 -> lo = mid + 1
                else -> return r
            }
        }
        return null
    }
}

/** The mapped composition (file header). */
data class CompositionSpec(
    val canvasW: Int,
    val canvasH: Int,
    /** Output (clock band) rate. */
    val outputFps: Int,
    /** Edit grid rate (every boundary is a P(k) of it). */
    val gridFps: Int,
    val durUs: Long,
    /** Background ARGB (drawn opaque). */
    val bg: Int,
    /** All sequences, in Media3 index order. */
    val sequences: List<SequenceSpec>,
    /** The plan's visual layers by id (for effect factories). */
    val layers: Map<String, PlanLayer>,
) {
    /** Visual layer sequences (indices 1..n), top → bottom. */
    val layerSequences: List<SequenceSpec> get() = sequences.filter { it.kind == SequenceKind.LAYERS }

    /** Sequences built from packing slots. */
    val slotSequences: List<SequenceSpec> get() = sequences.filter { it.slot != null }

    /** Audio sequences. */
    val audioSequences: List<SequenceSpec> get() = sequences.filter { it.kind == SequenceKind.AUDIO }

    /** The background sequence index. */
    val backgroundIndex: Int get() = sequences.first { it.kind == SequenceKind.BACKGROUND }.index

    /** Whether the plan has no duration (nothing to compose). */
    val isEmpty: Boolean get() = durUs <= 0L
}
