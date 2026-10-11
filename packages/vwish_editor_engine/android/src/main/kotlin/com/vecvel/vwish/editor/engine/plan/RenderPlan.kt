// OWNER: AND-08
//
// RenderPlan contract v1 (ARCH §11.2), the Kotlin twin of core's `render_plan.dart` (CORE-29).
// Engines see flat, fully lowered layers (ARCH §11.1: §11 overrides native.md §4.2): time maps,
// a fixed effect set, linear keyframes in absolute timeline µs, canvas masks, solids, sprites and
// audio segments with gain envelopes. Value types only; decoding is PlanReader's, validation
// PlanValidator's, canonical re-encoding PlanWriter's. Equality is structural (the patch
// classifier and the contract round-trip tests compare decoded values).

package com.vecvel.vwish.editor.engine.plan

/** Schema version this reader decodes (ARCH §11.9). */
const val RENDER_PLAN_VERSION: Int = 1

/** `"preview"` or `"export"`. */
enum class PlanTarget(val wire: String) {
    PREVIEW("preview"),
    EXPORT("export"),
}

/** Asset kinds (ARCH §11.2 Asset). */
enum class PlanAssetKind(val wire: String) {
    VIDEO("video"),
    AUDIO("audio"),
    IMAGE("image"),
    LUT("lut"),
    SPRITE("sprite"),
}

/** Transfer characteristics of a source; HDR sources are tone-mapped to SDR before effects. */
enum class PlanTransfer(val wire: String) {
    SDR("sdr"),
    HLG("hlg"),
    PQ("pq"),
}

/** Layer kinds (ARCH §11.2 Layer). */
enum class PlanLayerKind(val wire: String) {
    MEDIA("media"),
    IMAGE("image"),
    SOLID("solid"),
    SPRITE("sprite"),
}

/** Item mask shapes. */
enum class PlanMaskShape(val wire: String) {
    RECT("rect"),
    ELLIPSE("ellipse"),
}

/** Animatable channel names (ARCH §11.2 "Animatable channels"). */
object PlanChannels {
    const val XF_CX = "xf.cx"
    const val XF_CY = "xf.cy"
    const val XF_S = "xf.s"
    const val XF_R = "xf.r"
    const val XF_OP = "xf.op"
    const val REVEAL = "reveal"

    /** The eight colour adjustments, each [-1, 1], in the `adj` key order. */
    val ADJUST: List<String> = listOf(
        "adj.exposure", "adj.brightness", "adj.contrast", "adj.highlights",
        "adj.shadows", "adj.saturation", "adj.temperature", "adj.tint",
    )

    /** Detail channels, each [0, 1]. */
    val DETAIL: List<String> = listOf("detail.sharpen", "detail.blur", "detail.vignette")

    /** Item mask channels. */
    val MASK: List<String> = listOf("mask.cx", "mask.cy", "mask.w", "mask.h", "mask.r", "mask.feather", "mask.op")

    /** Every channel a layer `anim` may contain. */
    val ALL: Set<String> = setOf(XF_CX, XF_CY, XF_S, XF_R, XF_OP, REVEAL) + ADJUST + DETAIL + MASK

    /** Channels a canvas mask `anim` may contain. */
    val CANVAS_MASK: Set<String> = setOf("cx", "cy", "w", "h")
}

/**
 * Canvas (ARCH §11.2): output size and rate, the grid every edge lies on ([gridFps], the project
 * rate; equal to [fps] unless an export changes the rate, D-35) and the opaque background [bg]
 * (ARGB; its alpha is ignored when drawn).
 */
data class PlanCanvas(val w: Int, val h: Int, val fps: Int, val gridFps: Int = fps, val bg: Int = OPAQUE_BLACK) {
    /** Output frame grid. */
    val outputGrid: FrameGrid get() = FrameGrid.of(fps)

    /** Edit grid (project rate). */
    val grid: FrameGrid get() = FrameGrid.of(gridFps)

    companion object {
        /** `#000000FF`. */
        const val OPAQUE_BLACK: Int = 0xFF000000.toInt()
    }
}

/** An asset entry (ARCH §11.2 Asset). Optional fields are null when absent. */
data class PlanAsset(
    val kind: PlanAssetKind,
    val uri: String,
    val bookmark: String? = null,
    val fp: String = "",
    val proxyUri: String? = null,
    val w: Int? = null,
    val h: Int? = null,
    val rot: Int? = null,
    val durUs: Long? = null,
    val transfer: PlanTransfer = PlanTransfer.SDR,
    val hasAudio: Boolean? = null,
    val n: Int? = null,
    val sw: Int? = null,
    val sh: Int? = null,
    val sscale: Double? = null,
    val reveal: Boolean? = null,
)

/** One time-map segment `[t0, t1, s0, s1]`: timeline [t0, t1) shows source [s0, s1) (exact µs). */
data class MapSegment(val t0: Long, val t1: Long, val s0: Long, val s1: Long) {
    /** Source µs per timeline µs. */
    val rate: Double get() = (s1 - s0).toDouble() / (t1 - t0).toDouble()

    /** Exact source time at timeline [t] (unclamped, linear in this segment). */
    fun sourceAt(t: Double): Double = s0 + (t - t0) * (s1 - s0).toDouble() / (t1 - t0).toDouble()
}

/**
 * A keyframe channel `[[tUs, v], …]` in absolute timeline µs (ARCH §11.1 rule 2): linear between
 * keys, held outside them. Times are sorted and unique in valid plans.
 */
class Keyframes(times: LongArray, values: DoubleArray) {
    private val t: LongArray = times.copyOf()
    private val v: DoubleArray = values.copyOf()

    init {
        require(t.size == v.size) { "times and values differ in length" }
    }

    /** Number of keys. */
    val size: Int get() = t.size

    /** Whether there is no key. */
    fun isEmpty(): Boolean = t.isEmpty()

    /** Time of key [i]. */
    fun timeAt(i: Int): Long = t[i]

    /** Value of key [i]. */
    fun valueOf(i: Int): Double = v[i]

    /** Whether key times strictly increase. */
    fun isSortedUnique(): Boolean = (1 until t.size).all { t[it] > t[it - 1] }

    /** Whether any value lies outside [lo, hi] (or is NaN). */
    fun anyOutside(lo: Double, hi: Double): Boolean = v.any { !(it >= lo && it <= hi) }

    /** Value at integer time [time] (core `evaluateAnimKeys`). Requires at least one key. */
    fun valueAt(time: Long): Double {
        check(t.isNotEmpty()) { "no keys" }
        if (time <= t[0]) return v[0]
        val last = t.size - 1
        if (time >= t[last]) return v[last]
        val i = lowerIndex(time.toDouble())
        return v[i] + (v[i + 1] - v[i]) * (time - t[i]).toDouble() / (t[i + 1] - t[i]).toDouble()
    }

    /** Value at a real time [time] (audio sample instants, ARCH §11.6 Audio). */
    fun valueAt(time: Double): Double {
        check(t.isNotEmpty()) { "no keys" }
        if (time <= t[0]) return v[0]
        val last = t.size - 1
        if (time >= t[last]) return v[last]
        val i = lowerIndex(time)
        return v[i] + (v[i + 1] - v[i]) * (time - t[i]) / (t[i + 1] - t[i]).toDouble()
    }

    /** The index i with t[i] ≤ time < t[i + 1] (time strictly inside the key range). */
    private fun lowerIndex(time: Double): Int {
        var lo = 0
        var hi = t.size - 1
        while (hi - lo > 1) {
            val mid = (lo + hi) ushr 1
            if (t[mid] <= time) lo = mid else hi = mid
        }
        return lo
    }

    /** The keys as `[tUs, v]` pairs. */
    fun pairs(): List<Pair<Long, Double>> = t.indices.map { t[it] to v[it] }

    override fun equals(other: Any?): Boolean = other is Keyframes && other.t.contentEquals(t) && other.v.contentEquals(v)

    override fun hashCode(): Int = t.contentHashCode() * 31 + v.contentHashCode()

    override fun toString(): String = pairs().joinToString(prefix = "Keyframes[", postfix = "]") { "[${it.first}, ${it.second}]" }

    companion object {
        /** Keys from `[tUs, v]` pairs. */
        fun of(vararg keys: Pair<Long, Double>): Keyframes =
            Keyframes(LongArray(keys.size) { keys[it].first }, DoubleArray(keys.size) { keys[it].second })

        /** One constant key at time 0. */
        fun constant(v: Double): Keyframes = Keyframes(longArrayOf(0L), doubleArrayOf(v))
    }
}

/** A size in canvas px. */
data class PlanSize(val w: Double, val h: Double)

/** Normalized display-oriented crop `[l, t, r, b]`. */
data class PlanCrop(val l: Double, val t: Double, val r: Double, val b: Double) {
    /** Whether this is the default full frame. */
    val isFull: Boolean get() = l == 0.0 && t == 0.0 && r == 1.0 && b == 1.0

    companion object {
        /** `[0, 0, 1, 1]`. */
        val FULL = PlanCrop(0.0, 0.0, 1.0, 1.0)
    }
}

/** Placement `{cx, cy, s, r, fx, fy, op}`; null centres mean the canvas centre. */
data class PlanTransform(
    val cx: Double? = null,
    val cy: Double? = null,
    val s: Double = 1.0,
    val r: Double = 0.0,
    val fx: Boolean = false,
    val fy: Boolean = false,
    val op: Double = 1.0,
) {
    /** Whether every field has its default. */
    val isIdentity: Boolean get() = cx == null && cy == null && s == 1.0 && r == 0.0 && !fx && !fy && op == 1.0

    companion object {
        /** The default placement. */
        val IDENTITY = PlanTransform()
    }
}

/** Colour adjustments, each [-1, 1]. */
data class PlanAdjust(
    val exposure: Double = 0.0,
    val brightness: Double = 0.0,
    val contrast: Double = 0.0,
    val highlights: Double = 0.0,
    val shadows: Double = 0.0,
    val saturation: Double = 0.0,
    val temperature: Double = 0.0,
    val tint: Double = 0.0,
) {
    /** The values in `adj` key order (ARCH §11.2 Effects). */
    val values: List<Double> get() = listOf(exposure, brightness, contrast, highlights, shadows, saturation, temperature, tint)

    companion object {
        /** `adj` key names in order. */
        val NAMES: List<String> = listOf("exposure", "brightness", "contrast", "highlights", "shadows", "saturation", "temperature", "tint")

        /** From values in [NAMES] order. */
        fun of(values: List<Double>): PlanAdjust =
            PlanAdjust(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7])
    }
}

/** Detail effects, each [0, 1]. */
data class PlanDetail(val sharpen: Double = 0.0, val blur: Double = 0.0, val vignette: Double = 0.0)

/** LUT reference with intensity [0, 1]. */
data class PlanLut(val asset: String, val i: Double = 1.0)

/** Chroma key; [key] is 0xRRGGBB. */
data class PlanChroma(val key: Int, val sim: Double = 0.4, val smooth: Double = 0.1, val spill: Double = 0.3)

/** Item mask in layer-normalized space over `base`. */
data class PlanMask(
    val shape: PlanMaskShape,
    val cx: Double = 0.5,
    val cy: Double = 0.5,
    val w: Double = 1.0,
    val h: Double = 1.0,
    val r: Double = 0.0,
    val corner: Double = 0.0,
    val feather: Double = 0.0,
    val op: Double = 1.0,
    val inv: Boolean = false,
)

/** The fixed effect set of a layer (ARCH §11.2 Effects). */
data class PlanEffects(
    val adj: PlanAdjust? = null,
    val detail: PlanDetail? = null,
    val lut: PlanLut? = null,
    val chroma: PlanChroma? = null,
    val mask: PlanMask? = null,
) {
    /** Whether no effect is present. */
    val isEmpty: Boolean get() = adj == null && detail == null && lut == null && chroma == null && mask == null

    companion object {
        /** No effects. */
        val NONE = PlanEffects()
    }
}

/** Canvas-space mask (canvas px) multiplying the layer's alpha after placement. */
data class CanvasMask(
    val cx: Double,
    val cy: Double,
    val w: Double,
    val h: Double,
    val r: Double = 0.0,
    val feather: Double = 0.0,
    val inv: Boolean = false,
    val anim: Map<String, Keyframes> = emptyMap(),
)

/** One visual layer (ARCH §11.2 Layer). */
data class PlanLayer(
    val id: String,
    val z: Int,
    val seq: Int? = null,
    val t0: Long,
    val t1: Long,
    val kind: PlanLayerKind,
    val asset: String? = null,
    val map: List<MapSegment> = emptyList(),
    val hold: Boolean = false,
    val color: Int? = null,
    val base: PlanSize? = null,
    val crop: PlanCrop = PlanCrop.FULL,
    val xf: PlanTransform = PlanTransform.IDENTITY,
    val fx: PlanEffects = PlanEffects.NONE,
    val anim: Map<String, Keyframes> = emptyMap(),
    val cmasks: List<CanvasMask> = emptyList(),
) {
    /** Whether plan time [t] lies in the half-open range [t0, t1). */
    fun covers(t: Long): Boolean = t >= t0 && t < t1
}

/** One audio segment (ARCH §11.2 AudioSeg). */
data class AudioSeg(
    val id: String,
    val asset: String,
    val stream: Int = 0,
    val t0: Long,
    val t1: Long,
    val map: List<MapSegment>,
    val gain: Keyframes,
    val pitch: Boolean = true,
)

/** Preview requirements (informational). */
data class PlanRequirements(
    val offline: List<String> = emptyList(),
    val pendingReverse: List<String> = emptyList(),
    val pendingStill: List<String> = emptyList(),
)

/** A RenderPlan v1 (ARCH §11.2 Plan). */
data class RenderPlan(
    val v: Int = RENDER_PLAN_VERSION,
    val rev: Long,
    val target: PlanTarget,
    val canvas: PlanCanvas,
    val durUs: Long,
    val assets: Map<String, PlanAsset>,
    val layers: List<PlanLayer>,
    val audio: List<AudioSeg>,
    val req: PlanRequirements? = null,
) {
    /** The layer with [id], or null. */
    fun layer(id: String): PlanLayer? = layers.firstOrNull { it.id == id }
}

/** Upserts and removals of one id-keyed collection. */
data class PatchSet<T>(val upsert: List<T> = emptyList(), val remove: List<String> = emptyList()) {
    /** Whether nothing changes. */
    val isEmpty: Boolean get() = upsert.isEmpty() && remove.isEmpty()
}

/** A RenderPlan patch (ARCH §11.2 Patch). */
data class RenderPlanPatch(
    val v: Int = RENDER_PLAN_VERSION,
    val from: Long,
    val to: Long,
    val canvas: PlanCanvas? = null,
    val durUs: Long? = null,
    val assetUpserts: Map<String, PlanAsset> = emptyMap(),
    val assetRemovals: List<String> = emptyList(),
    val layers: PatchSet<PlanLayer> = PatchSet(),
    val audio: PatchSet<AudioSeg> = PatchSet(),
)

/** Param-only override of one layer (ARCH §11.2 Transient); null fields keep the layer's value. */
data class TransientLayer(
    val id: String,
    val xf: PlanTransform? = null,
    val crop: PlanCrop? = null,
    val base: PlanSize? = null,
    val fx: PlanEffects? = null,
    val anim: Map<String, Keyframes>? = null,
    val cmasks: List<CanvasMask>? = null,
)

/** A transient of one item's layers (ARCH §11.2 Transient): never revisioned, never persisted. */
data class PlanTransient(val v: Int = RENDER_PLAN_VERSION, val item: String, val layers: List<TransientLayer>)
