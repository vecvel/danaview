// OWNER: AND-18
//
// JVM test support for AND-18: a small preview plan (canvas 640×360 at 30 fps, 100 frames) with a
// media layer "a" over frames [0, 40), a solid "b" over everything, a media layer "c" over
// [60, 100) and a tone audio segment, built in code and validated.

package com.vecvel.danaview.editor.engine.render

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

object RenderPlans {
    const val FPS = 30
    const val FRAMES = 100L
    val grid: FrameGrid = FrameGrid.of(FPS)

    fun t(k: Long): Long = grid.timeOfFrame(k)

    fun media(id: String, k0: Long, k1: Long, z: Int, seq: Int, asset: String = "md_src"): PlanLayer = PlanLayer(
        id = id, z = z, seq = seq, t0 = t(k0), t1 = t(k1), kind = PlanLayerKind.MEDIA, asset = asset,
        map = listOf(MapSegment(t(k0), t(k1), t(k0), t(k1))), base = PlanSize(640.0, 360.0),
    )

    fun solid(id: String, k0: Long, k1: Long, z: Int, color: Int = 0xFF336699.toInt()): PlanLayer = PlanLayer(
        id = id, z = z, t0 = t(k0), t1 = t(k1), kind = PlanLayerKind.SOLID, color = color, base = PlanSize(100.0, 100.0),
    )

    val assets: Map<String, PlanAsset> = mapOf(
        "md_src" to PlanAsset(PlanAssetKind.VIDEO, "file:///fixtures/src.mp4", fp = "src", w = 1280, h = 720, durUs = 60_000_000),
        "md_other" to PlanAsset(PlanAssetKind.VIDEO, "file:///fixtures/other.mp4", fp = "other", w = 1280, h = 720, durUs = 60_000_000),
        "md_tone" to PlanAsset(PlanAssetKind.AUDIO, "file:///fixtures/tone.wav", fp = "tone", durUs = 60_000_000),
    )

    fun plan(
        layers: List<PlanLayer> = listOf(media("a#v", 0, 40, 10, 0), solid("b#s", 0, FRAMES, 30), media("c#v", 60, FRAMES, 20, 1)),
        target: PlanTarget = PlanTarget.PREVIEW,
        frames: Long = FRAMES,
        rev: Long = 1,
        canvas: PlanCanvas = PlanCanvas(640, 360, FPS),
        audio: Boolean = true,
        assets: Map<String, PlanAsset> = this.assets,
    ): RenderPlan {
        val dur = t(frames)
        val p = RenderPlan(
            rev = rev, target = target, canvas = canvas, durUs = dur, assets = assets,
            layers = layers.sortedWith(PlanValidator::compareLayers),
            audio = if (!audio) emptyList() else listOf(
                AudioSeg(id = "tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 1.0)),
            ),
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(p))
        return p
    }
}
