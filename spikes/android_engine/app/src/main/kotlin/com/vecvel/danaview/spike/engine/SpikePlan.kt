package com.vecvel.danaview.spike.engine

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/**
 * A miniature RenderPlan for the spike (ARCH §11.2 reduced to what AND-01 needs). Times are frame
 * indices on the plan grid ([fps]); the mapper anchors every boundary at P(k) (D-35).
 */
data class SpikeLayer(
    val id: String,
    /** Visual sequence slot (1 = top video sequence), ARCH §13.3 "Sequence stack". */
    val seq: Int,
    val k0: Long,
    val k1: Long,
    /** file:// URI of the source. */
    val uri: String,
    /** Exact source time at k0 (µs), the plan's `map[0].s0`. */
    val srcStartUs: Long,
    /** Placement in canvas px: x, y (top-left, y down), w, h. */
    val rect: FloatArray,
    val tint: FloatArray = floatArrayOf(1f, 1f, 1f),
    val alpha: Float = 1f,
    /** Constant output colour (straight RGBA) instead of sampling the source (V-N4). */
    val solid: FloatArray? = null,
    val speed: Float = 1f,
) {
    fun toParams() = LayerParams(id, k0, k1, rect, tint, alpha, solid)
}

data class SpikeAudio(val id: String, val lane: Int, val k0: Long, val k1: Long, val uri: String, val srcStartUs: Long)

data class SpikePlan(
    val canvasW: Int,
    val canvasH: Int,
    /** Output (clock band) rate. */
    val fps: Int,
    /** Grid of the layer edges (project rate); equals [fps] except in export-rate tests. */
    val gridFps: Int = fps,
    val durFrames: Long,
    val layers: List<SpikeLayer>,
    val audio: List<SpikeAudio> = emptyList(),
    /** Background solid colour 0xRRGGBB. */
    val bg: Int = 0x336699,
) {
    val visualSequenceCount: Int get() = layers.maxOfOrNull { it.seq } ?: 0
    val audioLaneCount: Int get() = audio.maxOfOrNull { it.lane + 1 } ?: 0
    val durUs: Long get() = GridTime.platformTimeOfFrame(durFrames, gridFps)
    fun layersOf(seq: Int) = layers.filter { it.seq == seq }.sortedBy { it.k0 }
    fun bgRgb(): FloatArray = floatArrayOf(((bg shr 16) and 0xff) / 255f, ((bg shr 8) and 0xff) / 255f, (bg and 0xff) / 255f)
}

/** Param snapshot of one layer as the GL effects read it (spike ParamSnapshot, ARCH §11.2). */
data class LayerParams(
    val id: String,
    val k0: Long,
    val k1: Long,
    val rect: FloatArray,
    val tint: FloatArray,
    val alpha: Float,
    val solid: FloatArray?,
)

/**
 * Per-sequence `AtomicReference<List<LayerParams>>` read by [PlaceEffect] at draw time and by the
 * gating compositor settings. Param edits swap the reference (ARCH §13.3 "GL effects").
 */
class ParamStore(val gridFps: Int) {
    private val bySeq = ConcurrentHashMap<Int, AtomicReference<List<LayerParams>>>()

    fun ref(seq: Int): AtomicReference<List<LayerParams>> = bySeq.getOrPut(seq) { AtomicReference(emptyList()) }

    fun set(seq: Int, layers: List<LayerParams>) = ref(seq).set(layers)

    fun update(seq: Int, transform: (LayerParams) -> LayerParams) {
        val r = ref(seq)
        r.set(r.get().map(transform))
    }

    /**
     * Active layer of [seq] for a platform time [ptsUs] of an output grid at [outputFps]: the
     * platform-time rule k = frameIndexNearest(pts), evaluated at T = timeOfFrame(k) against the
     * half-open layer range [timeOfFrame(k0), timeOfFrame(k1)) of the plan grid (ARCH §5, §11.5).
     */
    fun activeAt(seq: Int, ptsUs: Long, outputFps: Int): LayerParams? {
        val k = GridTime.frameIndexNearest(ptsUs, outputFps)
        val t = GridTime.timeOfFrame(k, outputFps)
        return ref(seq).get().firstOrNull {
            t >= GridTime.timeOfFrame(it.k0, gridFps) && t < GridTime.timeOfFrame(it.k1, gridFps)
        }
    }

    fun loadFrom(plan: SpikePlan) {
        bySeq.clear()
        for (s in 1..plan.visualSequenceCount) set(s, plan.layersOf(s).map { it.toParams() })
    }
}
