@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// Every contract plan maps to a Media3 1.11.1 Transformer Composition (ARCH §13.3): sequence count
// and order, track types (clock band {VIDEO, AUDIO}, layers {VIDEO}, audio {AUDIO}), and Media3's
// own presentation duration of every item equal to the spec's P(k)-anchored duration, so every
// cumulative boundary is P(k) inside Media3 too; composition audio
// Sonic + channel mixing; gating compositor settings; images at the output fps; full source
// durations; speed providers and the fps cap; empty and `hold` plans refused for export.

package com.vecvel.danaview.editor.engine.composition

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.TestFixtures
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
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class CompositionBuildInstrumentedTest {
    private val images = PngCompositionImages(File(TestFixtures.targetContext.cacheDir, "and08_images"))
    private val mapper = CompositionMapper(ConstantRateTimeline())

    private fun plans(): Map<String, RenderPlan> = ContractAssets.names()
        .filter { JSONObject(ContractAssets.text("", it)).has("rev") }
        .associateWith { PlanReader.readPlan(ContractAssets.bytes("", it)) }

    private fun build(plan: RenderPlan): Media3Composition.Built =
        Media3Composition.build(mapper.map(plan), images, EffectChainFactory.NONE, AtomicReference(ParamSnapshot.of(plan)))

    @Test
    fun everyContractPlanBuildsAMedia3Composition() {
        val plans = plans()
        assertTrue(plans.size >= 20)
        var built = 0
        for ((name, plan) in plans) {
            if (plan.durUs == 0L || plan.layers.any { it.hold }) continue
            val result = build(plan)
            val spec = result.spec
            val c = result.composition
            assertEquals("$name: sequences", spec.sequences.size, c.sequences.size)
            assertTrue("$name: gating settings", c.videoCompositorSettings is LayerGatingCompositorSettings)
            assertEquals("$name: HDR tone-mapped", Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL, c.hdrMode)
            assertEquals("$name: composition audio Sonic + mixing", 2, c.effects.audioProcessors.size)
            assertFalse("$name: no deprecated force flags", c.forceAudioTrack)
            for ((s, m3) in spec.sequences.zip(c.sequences)) {
                val types = when (s.trackTypes) {
                    TrackTypes.VIDEO -> setOf(C.TRACK_TYPE_VIDEO)
                    TrackTypes.AUDIO -> setOf(C.TRACK_TYPE_AUDIO)
                    TrackTypes.VIDEO_AND_AUDIO -> setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)
                }
                assertEquals("$name/${s.index}: track types", types, m3.trackTypes)
                assertEquals("$name/${s.index}: items", s.items.size, m3.editedMediaItems.size)
                var cursor = 0L
                for ((item, e) in s.items.zip(m3.editedMediaItems)) {
                    // Media3's own duration of every item is the anchored duration (boundaries at P(k)).
                    assertEquals("$name/${s.index}/${item.layerId ?: item.kind}: Media3 duration", item.durationUs, e.presentationDurationUs)
                    cursor += e.presentationDurationUs
                    when (item.kind) {
                        ItemKind.MEDIA -> {
                            assertTrue(e.removeAudio)
                            assertEquals(item.sourceDurationUs, e.durationUs)
                            assertEquals(item.clipStartUs, e.mediaItem.clippingConfiguration.startPositionUs)
                            assertEquals(item.clipEndUs, e.mediaItem.clippingConfiguration.endPositionUs)
                            assertEquals(item.frameRate ?: C.RATE_UNSET_INT, e.frameRate)
                        }
                        ItemKind.AUDIO -> {
                            assertTrue(e.removeVideo)
                            assertEquals(1, e.effects.audioProcessors.size) // GainProcessor
                        }
                        ItemKind.GAP, ItemKind.IMAGE, ItemKind.SOLID, ItemKind.SPRITE, ItemKind.CLOCK, ItemKind.BACKGROUND ->
                            assertEquals("$name: images at the output fps", spec.outputFps, e.frameRate)
                        ItemKind.AUDIO_GAP -> Unit
                    }
                }
                assertEquals("$name/${s.index}: Media3 sequence length = durUs", plan.durUs, cursor)
            }
            built++
        }
        assertTrue(built >= 18)
    }

    @Test
    fun speedItemsCarryTheirProviderAndTheFpsCap() {
        val plan = plans().getValue("speed_ramp_multi_segment.json")
        val spec = mapper.map(plan)
        val c = build(plan).composition
        val grid = FrameGrid.of(plan.canvas.gridFps)
        var checked = 0
        for ((s, m3) in spec.sequences.zip(c.sequences)) for ((item, e) in s.items.zip(m3.editedMediaItems)) {
            if (item.speed == null) continue
            // EditedMediaItem keeps its own provider object; it must answer like ours.
            val theirs = e.speedParameters.speedProvider
            val ours = item.speed!!
            for (i in 0 until ours.segmentCount) {
                val t = ours.startOf(i)
                assertEquals(ours.getSpeed(t), theirs.getSpeed(t), 0f)
                assertEquals(ours.getNextSpeedChangeTimeUs(t), theirs.getNextSpeedChangeTimeUs(t))
            }
            assertEquals(item.keepPitch, e.speedParameters.shouldMaintainPitch)
            if (item.kind == ItemKind.MEDIA && item.maxRate > 1.0) assertEquals(grid.fps, e.frameRate)
            checked++
        }
        assertTrue("the ramp fixture has speed items", checked >= 2)
    }

    /**
     * 2,000 items (1,500 main clips, every fifth at 2×, 500 overlay images/clips on three more
     * slots, plus audio segments) mapped and built on the emulator. The criterion (≤ 150 ms on a
     * mid-tier device) needs hardware (deferred: no device); this records the emulator number and
     * guards against gross regressions only.
     */
    @Test
    fun twoThousandItemMappingOnTheEmulator() {
        val g = FrameGrid.of(30)
        val layers = ArrayList<PlanLayer>()
        val audio = ArrayList<AudioSeg>()
        var k = 0L
        fun clip(id: String, z: Int, seq: Int, t0: Long, t1: Long, s0: Long, rate: Double) = PlanLayer(
            id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md_v",
            map = listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate))), base = PlanSize(1280.0, 720.0),
        )
        for (i in 0 until 1500) {
            val n = 15L + (i % 7)
            val t0 = g.timeOfFrame(k)
            val t1 = g.timeOfFrame(k + n)
            layers += clip("it_m$i#v", 10, 0, t0, t1, 1_000L * i, if (i % 5 == 0) 2.0 else 1.0)
            if (i % 3 == 0) audio += AudioSeg("it_m$i#a", "md_v", 0, t0, t1, listOf(MapSegment(t0, t1, 0, t1 - t0)), Keyframes.constant(1.0))
            k += n
        }
        for (i in 0 until 500) {
            val t0 = g.timeOfFrame(i * 41L)
            val t1 = g.timeOfFrame(i * 41L + 20)
            val z = 10010 + 10 * (i % 4)
            layers += if (i % 2 == 0) {
                PlanLayer(id = "it_i$i#v", z = z, t0 = t0, t1 = t1, kind = PlanLayerKind.IMAGE, asset = "md_i", base = PlanSize(512.0, 512.0))
            } else {
                clip("it_p$i#v", z, 1 + (i % 3), t0, t1, 0, 1.0)
            }
        }
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = g.timeOfFrame(k),
            assets = mapOf(
                "md_v" to PlanAsset(PlanAssetKind.VIDEO, "file:///nonexistent/v.mp4", fp = "v", w = 1280, h = 720),
                "md_i" to PlanAsset(PlanAssetKind.IMAGE, "file:///nonexistent/i.png", fp = "i", w = 512, h = 512),
            ),
            layers = layers.sortedWith(PlanValidator::compareLayers),
            audio = audio.sortedWith(PlanValidator::compareAudio),
        )
        val options = CompositionMapper.Options(validate = false)
        repeat(3) { mapper.map(plan, options) } // warm-up
        val runs = 5
        var t = System.nanoTime()
        var spec: CompositionSpec? = null
        repeat(runs) { spec = mapper.map(plan, options) }
        val mapMs = (System.nanoTime() - t) / 1e6 / runs
        t = System.nanoTime()
        val built = Media3Composition.build(spec!!, images, EffectChainFactory.NONE, AtomicReference(ParamSnapshot.of(plan)))
        val buildMs = (System.nanoTime() - t) / 1e6
        val items = spec!!.sequences.sumOf { it.items.size }
        Log.i("AND08Build", "2,000-item plan (${layers.size + audio.size} items, $items sequence items): map %.1f ms, Media3 build %.1f ms (emulator)".format(mapMs, buildMs))
        assertTrue(layers.size + audio.size >= 2000)
        assertEquals(spec!!.sequences.size, built.composition.sequences.size)
        assertTrue("mapping regressed grossly: $mapMs ms on the emulator", mapMs < 2_000)
    }

    @Test
    fun audioItemsCarryTheirStreamTag() {
        // effects_every_static_key.json plays audio stream 1: its AUDIO item is tagged for
        // AudioStreamAssetLoaderFactory and the build reports that it selects streams.
        val plan = plans().getValue("effects_every_static_key.json")
        assertTrue(plan.audio.any { it.stream == 1 })
        val result = build(plan)
        assertTrue(result.selectsAudioStreams)
        val tagged = result.spec.audioSequences.zip(result.composition.sequences.takeLast(result.spec.audioSequences.size))
            .flatMap { (s, m3) -> s.items.zip(m3.editedMediaItems).filter { it.first.kind == ItemKind.AUDIO } }
        assertTrue(tagged.isNotEmpty())
        for ((item, edited) in tagged) assertEquals(item.segmentId, item.stream, edited.mediaItem.audioStream())
        val plain = plans().getValue("grid_cuts_30fps.json")
        assertFalse(build(plain).selectsAudioStreams)
    }

    @Test
    fun emptyAndHoldPlansAreRefusedForExport() {
        val all = plans()
        for (name in listOf("empty_plan.json", "hold_pending_still.json")) {
            try {
                build(all.getValue(name))
                fail("$name built")
            } catch (e: EngineException) {
                assertEquals(EngineErrorCode.planInvalid, e.code)
            }
        }
    }
}
