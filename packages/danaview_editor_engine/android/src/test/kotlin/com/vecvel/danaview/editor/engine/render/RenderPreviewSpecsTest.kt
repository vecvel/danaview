// OWNER: AND-18
//
// RenderPreviewSpecs: output size and encoder settings (H.264 all-intra at the preview size, project
// fps), the export plan of a preview range plan (originals, no audio, one padding frame, refusals),
// the video-only composition, the part-file convention and the stale-part sweep.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.FakeSourceTimeline
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.export.ExportVideoCodec
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanRequirements
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class RenderPreviewSpecsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun code(block: () -> Unit): EngineErrorCode? = try {
        block()
        null
    } catch (e: EngineException) {
        e.code
    }

    @Test
    fun outputSizeFitsThePreviewLongSideWithEvenSides() {
        assertEquals(640 to 360, RenderPreviewSpecs.outputSize(640, 360, 960))
        assertEquals(960 to 540, RenderPreviewSpecs.outputSize(1920, 1080, 960))
        assertEquals(640 to 360, RenderPreviewSpecs.outputSize(1920, 1080, 640))
        assertEquals(360 to 640, RenderPreviewSpecs.outputSize(1080, 1920, 640))
        // Odd results round to even and never exceed the cap.
        val (w, h) = RenderPreviewSpecs.outputSize(1001, 333, 640)
        assertTrue(w % 2 == 0 && h % 2 == 0 && maxOf(w, h) <= 640)
        assertEquals(640 to 212, RenderPreviewSpecs.outputSize(1001, 333, 640))
        // Never upscaled; no cap keeps the canvas (made even).
        assertEquals(320 to 180, RenderPreviewSpecs.outputSize(320, 180, 1280))
        assertEquals(322 to 180, RenderPreviewSpecs.outputSize(321, 179, 0))
    }

    @Test
    fun settingsAreAllIntraH264AtTheProjectFps() {
        val plan = RenderPreviewSpecs.exportPlan(RenderPlans.plan(canvas = PlanCanvas(1920, 1080, 60)), null)
        val s = RenderPreviewSpecs.settings(plan, 960)
        assertEquals(ExportVideoCodec.H264, s.codec)
        assertEquals(960, s.width)
        assertEquals(540, s.height)
        assertEquals(60, s.fps)
        assertEquals(0, s.keyframeIntervalMs)
        assertEquals(0f, s.iFrameIntervalSeconds)
        assertEquals((960L * 540 * 60 * RenderPreviewSpecs.BITS_PER_PIXEL).toInt(), s.videoBitrate)
        // Bounds.
        assertEquals(RenderPreviewSpecs.MIN_BITRATE, RenderPreviewSpecs.videoBitrate(64, 64, 24))
        assertEquals(RenderPreviewSpecs.MAX_BITRATE, RenderPreviewSpecs.videoBitrate(3840, 2160, 60))
    }

    @Test
    fun exportPlanRendersOriginalsWithoutAudioOverOneMoreFrame() {
        val range = RenderPlans.plan()
        val p = RenderPreviewSpecs.exportPlan(range, null)
        assertEquals(PlanTarget.EXPORT, p.target)
        assertEquals(emptyList<Any>(), p.audio)
        assertEquals(range.layers, p.layers)
        assertEquals(range.canvas, p.canvas)
        assertEquals(range.assets, p.assets)
        assertEquals(RenderPlans.t(RenderPlans.FRAMES + 1), p.durUs)
        assertEquals(RenderPlans.FRAMES, RenderPreviewSpecs.rangeFrames(range))
        assertEquals(RenderPlans.FRAMES + 1, RenderPreviewSpecs.rangeFrames(p))
    }

    @Test
    fun exportPlanRefusesWhatCannotBeRendered() {
        assertEquals(EngineErrorCode.planInvalid, code { RenderPreviewSpecs.exportPlan(RenderPlans.plan(target = PlanTarget.EXPORT), null) })
        val held = RenderPlans.plan(layers = listOf(RenderPlans.media("a#v", 0, 40, 10, 0).copy(hold = true)))
        assertEquals(EngineErrorCode.planInvalid, code { RenderPreviewSpecs.exportPlan(held, null) })
        val pending = RenderPlans.plan().copy(req = PlanRequirements(pendingReverse = listOf("a")))
        assertEquals(EngineErrorCode.planInvalid, code { RenderPreviewSpecs.exportPlan(pending, null) })
        val offline = RenderPlans.plan().copy(req = PlanRequirements(offline = listOf("a")))
        assertEquals(EngineErrorCode.mediaOffline, code { RenderPreviewSpecs.exportPlan(offline, null) })
        val empty = RenderPlans.plan().copy(durUs = 0, layers = emptyList(), audio = emptyList())
        assertEquals(EngineErrorCode.planInvalid, code { RenderPreviewSpecs.exportPlan(empty, null) })
    }

    @Test
    fun renderFilesAreNeverInputs() {
        val cache = File(tmp.root, "cache/danaview/editor")
        val support = File(tmp.root, "files/danaview/editor")
        val paths = Paths.fromDart(cache.absolutePath, support.absolutePath)
        val renders = RenderPreviewSpecs.rendersDir(paths)
        assertEquals(File(cache, "renders"), renders)
        val renderAsset = PlanAsset(PlanAssetKind.VIDEO, "file://" + File(renders, "abc.mp4").absolutePath.replace('\\', '/'), fp = "r", w = 640, h = 360)
        val reads = RenderPlans.plan(assets = RenderPlans.assets + ("md_other" to renderAsset))
        val e = try {
            RenderPreviewSpecs.exportPlan(reads, renders)
            fail("a render file was accepted as an input")
            null
        } catch (x: EngineException) {
            x
        }
        assertEquals(EngineErrorCode.planInvalid, e!!.code)
        assertEquals("md_other", e.itemId)
        // Ordinary sources pass.
        RenderPreviewSpecs.exportPlan(RenderPlans.plan(), renders)
    }

    @Test
    fun videoOnlyKeepsEveryVisualSequenceAndDropsAudio() {
        val export = RenderPreviewSpecs.exportPlan(RenderPlans.plan(), null).copy(audio = RenderPlans.plan().audio)
        val full = CompositionMapper(FakeSourceTimeline()).map(export, CompositionMapper.Options(useProxies = false))
        assertTrue("the full mapping has audio", full.audioSequences.isNotEmpty())
        val v = RenderPreviewSpecs.videoOnly(full)
        assertEquals(emptyList<Any>(), v.audioSequences)
        assertEquals(full.layerSequences.map { it.items }, v.layerSequences.map { it.items })
        val clock = v.sequences.first()
        assertEquals(SequenceKind.CLOCK_BAND, clock.kind)
        assertEquals(TrackTypes.VIDEO, clock.trackTypes)
        assertEquals(SequenceKind.BACKGROUND, v.sequences.last().kind)
        assertEquals(v.sequences.indices.toList(), v.sequences.map { it.index })
        assertTrue(v.sequences.none { it.trackTypes != TrackTypes.VIDEO && it.kind != SequenceKind.LAYERS })
    }

    @Test
    fun partFilesAndTheStaleSweep() {
        val out = File(tmp.root, "renders/h1.mp4")
        assertEquals(File(tmp.root, "renders/h1.mp4.part"), RenderPreviewSpecs.partFile(out))
        val dir = File(tmp.root, "renders").apply { mkdirs() }
        File(dir, "h1.mp4").writeText("done")
        File(dir, "h2.mp4.part").writeText("partial")
        File(dir, "index.json").writeText("{}")
        assertEquals(listOf("h2.mp4.part"), RenderPreviewSpecs.staleParts(dir).map { it.name })
        assertEquals(emptyList<File>(), RenderPreviewSpecs.staleParts(File(tmp.root, "missing")))
        assertFalse(RenderPreviewSpecs.staleParts(dir).any { it.name == "h1.mp4" })
    }
}
