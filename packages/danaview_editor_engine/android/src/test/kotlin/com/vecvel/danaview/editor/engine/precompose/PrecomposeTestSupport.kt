// OWNER: AND-19
//
// JVM test support for AND-19: export plans with packed media slots, interleaved non-media layers
// and audio; the mapped export composition (AND-08's mapper over a constant-rate fake source
// timeline); and a recording PassRunner double the tests drive pass by pass.

package com.vecvel.danaview.editor.engine.precompose

import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.FakeSourceTimeline
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.export.ExportJob
import com.vecvel.danaview.editor.engine.export.precompose.PassRequest
import com.vecvel.danaview.editor.engine.export.precompose.PassRunListener
import com.vecvel.danaview.editor.engine.export.precompose.PassRunner
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.Assert.assertEquals

/** Plans built in code (all validated). */
object PrecomposePlans {
    const val SRC = "file:///fixtures/src.mp4"
    const val TONE = "file:///fixtures/tone.wav"

    /** A slot description: media layers on [grid frames) of one slot. */
    data class Slot(val ranges: List<Pair<Long, Long>>)

    /**
     * [slots] packed slots (slot i at z = 10 + 10·i, seq i), each holding its [Slot.ranges] (grid
     * frame ranges), [extra] non-media layers, and a tone audio segment over the whole plan when
     * [audio].
     */
    fun plan(
        slots: List<Slot>,
        frames: Long = 60,
        fps: Int = 30,
        gridFps: Int = fps,
        extra: List<PlanLayer> = emptyList(),
        audio: Boolean = false,
        w: Int = 1280,
        h: Int = 720,
    ): RenderPlan {
        val g = FrameGrid.of(gridFps)
        val dur = g.timeOfFrame(frames)
        val layers = ArrayList<PlanLayer>()
        for ((i, s) in slots.withIndex()) {
            for ((j, r) in s.ranges.withIndex()) {
                val t0 = g.timeOfFrame(r.first)
                val t1 = g.timeOfFrame(r.second)
                layers += PlanLayer(
                    id = "it_s${i}_$j#v", z = 10 + 10 * i, seq = i, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md_src",
                    map = listOf(MapSegment(t0, t1, t0, t1)), base = PlanSize(w / 2.0, h / 2.0),
                )
            }
        }
        layers += extra
        val segs = if (!audio) emptyList() else listOf(
            AudioSeg(id = "it_tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 1.0)),
        )
        val plan = RenderPlan(
            rev = 7, target = PlanTarget.EXPORT, canvas = PlanCanvas(w, h, fps, gridFps), durUs = dur,
            assets = mapOf(
                "md_src" to PlanAsset(PlanAssetKind.VIDEO, SRC, fp = "src", w = w, h = h, durUs = 60_000_000),
                "md_tone" to PlanAsset(PlanAssetKind.AUDIO, TONE, fp = "tone", durUs = 60_000_000),
                "im_logo" to PlanAsset(PlanAssetKind.IMAGE, "file:///fixtures/logo.png", fp = "logo", w = 256, h = 256),
            ),
            layers = layers.sortedWith(PlanValidator::compareLayers),
            audio = segs,
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(plan))
        return plan
    }

    /** [n] slots, each one layer over the whole plan. */
    fun overlapping(n: Int, frames: Long = 60, audio: Boolean = false, extra: List<PlanLayer> = emptyList()): RenderPlan =
        plan(List(n) { Slot(listOf(0L to frames)) }, frames = frames, audio = audio, extra = extra)

    /** An image layer at [z] over grid frames [k0, k1). */
    fun image(id: String, z: Int, k0: Long, k1: Long, fps: Int = 30): PlanLayer {
        val g = FrameGrid.of(fps)
        return PlanLayer(id = id, z = z, t0 = g.timeOfFrame(k0), t1 = g.timeOfFrame(k1), kind = PlanLayerKind.IMAGE, asset = "im_logo", base = PlanSize(256.0, 256.0))
    }

    /** A solid layer at [z] over grid frames [k0, k1). */
    fun solid(id: String, z: Int, k0: Long, k1: Long, fps: Int = 30): PlanLayer {
        val g = FrameGrid.of(fps)
        return PlanLayer(id = id, z = z, t0 = g.timeOfFrame(k0), t1 = g.timeOfFrame(k1), kind = PlanLayerKind.SOLID, color = 0xFF336699.toInt(), base = PlanSize(100.0, 100.0))
    }

    /** The export mapping of [plan] (originals, constant-rate fake sources). */
    fun map(plan: RenderPlan): CompositionSpec = CompositionMapper(FakeSourceTimeline()).map(plan, CompositionMapper.Options(useProxies = false))
}

/** A recording [PassRunner]: the test completes, fails or reports progress of the current pass. */
class RecordingRunner : PassRunner {
    class Started(val job: ExportJob, val request: PassRequest, val listener: PassRunListener) {
        var cancelled = 0
    }

    val started = ArrayList<Started>()

    val current: Started get() = started.last()

    override fun run(job: ExportJob, request: PassRequest, listener: PassRunListener): Cancellable {
        val s = Started(job, request, listener)
        started += s
        // A running Transformer has created its output by now (InAppMp4Muxer, AND-11 measurement).
        request.output.parentFile?.mkdirs()
        request.output.writeBytes(ByteArray(16))
        return Cancellable { s.cancelled++ }
    }

    /** Completes the current pass with [bytes] of output. */
    fun complete(encoder: String? = "c2.qti.avc.encoder", bytes: Int = 4096) {
        val s = current
        s.request.output.writeBytes(ByteArray(bytes))
        s.listener.onCompleted(encoder)
    }

    fun progress(f: Double) = current.listener.onProgress(f)
}
