@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// CompositionMapper on the JVM (ARCH §13.3, §5 rule 3, D-35, D-38; AND-01 §6.7):
// - every contract plan maps; every sequence lasts durUs; every item and gap boundary is P(k);
// - frame_grid vectors: boundaries at P(k) at 24/25/30/48/50/60 (k ≡ 0, 1, 2 mod 3, 1 h, 24 h);
// - grid_cuts_30fps: gating at P(k) (and anywhere in V-N1's −1…+500 µs window) matches
//   expected_active.json for every frame;
// - packing vectors: one sequence per slot, slots stacked by seq;
// - z-order: non-media layers stacked between slots, split when no single position works;
// - a no-audio plan still has an audio track (clock band {VIDEO, AUDIO}), audio colours, speed caps.

package com.vecvel.danaview.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.SpeedProviderUtil
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
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
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CompositionMapperTest {
    private val timeline = FakeSourceTimeline(fps = 30, offsetUs = 0L)
    private val mapper = CompositionMapper(timeline)

    // ------------------------------------------------------------------ helpers

    private val video = PlanAsset(PlanAssetKind.VIDEO, "file:///v.mp4", fp = "fv", w = 1920, h = 1080, durUs = 3_600_000_000L)
    private val image = PlanAsset(PlanAssetKind.IMAGE, "file:///p.jpg", fp = "fi", w = 800, h = 600)
    private val music = PlanAsset(PlanAssetKind.AUDIO, "file:///m.m4a", fp = "fm", durUs = 3_600_000_000L)

    private fun media(id: String, z: Int, seq: Int, t0: Long, t1: Long, s0: Long = t0, rate: Double = 1.0) = PlanLayer(
        id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md_v",
        map = listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate))), base = PlanSize(1920.0, 1080.0),
    )

    private fun imageLayer(id: String, z: Int, t0: Long, t1: Long) =
        PlanLayer(id = id, z = z, t0 = t0, t1 = t1, kind = PlanLayerKind.IMAGE, asset = "im_p", base = PlanSize(800.0, 600.0))

    private fun solid(id: String, z: Int, t0: Long, t1: Long) = PlanLayer(id = id, z = z, t0 = t0, t1 = t1, kind = PlanLayerKind.SOLID, color = 0xFF000000.toInt())

    private fun plan(layers: List<PlanLayer>, durUs: Long, fps: Int = 30, gridFps: Int = fps, audio: List<AudioSeg> = emptyList(), target: PlanTarget = PlanTarget.EXPORT) =
        RenderPlan(
            rev = 1, target = target, canvas = PlanCanvas(1920, 1080, fps, gridFps), durUs = durUs,
            assets = mapOf("md_v" to video, "im_p" to image, "md_m" to music),
            layers = layers.sortedWith(PlanValidator::compareLayers), audio = audio.sortedWith(PlanValidator::compareAudio),
        )

    private fun media3Duration(item: ItemSpec): Long =
        item.speed?.let { SpeedProviderUtil.getDurationAfterSpeedProviderApplied(it, item.clipEndUs - item.clipStartUs) } ?: (item.clipEndUs - item.clipStartUs)

    /** Structural checks every mapped spec must pass. */
    private fun checkSpec(name: String, plan: RenderPlan, spec: CompositionSpec) {
        val grid = FrameGrid.of(plan.canvas.gridFps)
        assertEquals("$name: clock band first", SequenceKind.CLOCK_BAND, spec.sequences[0].kind)
        assertEquals("$name: clock band carries audio (D-38)", TrackTypes.VIDEO_AND_AUDIO, spec.sequences[0].trackTypes)
        assertEquals("$name: indices", spec.sequences.indices.toList(), spec.sequences.map { it.index })
        val bg = spec.backgroundIndex
        assertTrue("$name: layer sequences sit between the clock band and the background", spec.sequences.subList(1, bg).all { it.kind == SequenceKind.LAYERS })
        assertTrue("$name: audio after the background", spec.sequences.drop(bg + 1).all { it.kind == SequenceKind.AUDIO })
        assertEquals("$name: one sequence per packing slot", plan.layers.mapNotNull { it.seq }.toSet().size, spec.slotSequences.size)
        if (plan.durUs == 0L) return
        for (s in spec.sequences) {
            assertEquals("$name/${s.index}: sequence duration equals durUs", plan.durUs, s.durationUs)
            var cursor = 0L
            for (item in s.items) {
                assertEquals("$name/${s.index}: contiguous", cursor, item.startUs)
                assertTrue("$name/${s.index}: positive", item.endUs > item.startUs)
                assertEquals("$name/${s.index}: start at P(k0)", grid.platformTimeOfFrame(item.k0), item.startUs)
                val expectedEnd = if (item.endUs == plan.durUs) plan.durUs else grid.platformTimeOfFrame(item.k1)
                assertEquals("$name/${s.index}: end at P(k1)", expectedEnd, item.endUs)
                if (item.kind == ItemKind.MEDIA && !item.hold) {
                    assertEquals("$name/${item.layerId}: Media3 duration is the anchored duration", item.durationUs, media3Duration(item))
                    assertEquals("$name/${item.layerId}: rule-frame clip start", timeline.ruleFramePtsUs(item.uri!!, item.planSourceStartUs), item.clipStartUs)
                    assertNotNull("$name: full source duration", item.sourceDurationUs)
                    assertTrue("$name: clip inside the source", item.clipEndUs <= item.sourceDurationUs!!)
                    assertEquals("$name: fps cap above 1x", if (item.maxRate > 1.0) plan.canvas.gridFps else null, item.frameRate)
                }
                if (item.kind == ItemKind.AUDIO) {
                    assertEquals("$name/${item.segmentId}: audio duration", item.durationUs, media3Duration(item))
                    assertNotNull(item.gain)
                }
                if (item.kind in setOf(ItemKind.GAP, ItemKind.IMAGE, ItemKind.SOLID, ItemKind.SPRITE, ItemKind.CLOCK, ItemKind.BACKGROUND)) {
                    assertEquals("$name: generated images run at the output fps", plan.canvas.fps, item.frameRate)
                }
                cursor = item.endUs
            }
        }
        // Every visual layer is covered exactly once over its range.
        for (l in plan.layers) {
            val ranges = spec.layerSequences.flatMap { s -> s.active.filter { it.layerId == l.id } }.sortedBy { it.t0 }
            assertTrue("$name: ${l.id} placed", ranges.isNotEmpty())
            assertEquals("$name: ${l.id} starts", l.t0, ranges.first().t0)
            assertEquals("$name: ${l.id} ends", l.t1, ranges.last().t1)
            for (i in 1 until ranges.size) assertEquals("$name: ${l.id} pieces contiguous", ranges[i - 1].t1, ranges[i].t0)
        }
        checkDrawOrder(name, plan, spec)
    }

    /** Every pair of time-overlapping layers in different sequences is stacked in draw order. */
    private fun checkDrawOrder(name: String, plan: RenderPlan, spec: CompositionSpec) {
        val pieces = spec.layerSequences.flatMap { s -> s.active.map { s.index to it } }
        val byId = plan.layers.associateBy { it.id }
        for ((ia, a) in pieces) for ((ib, b) in pieces) {
            if (ia == ib || !(a.t0 < b.t1 && b.t0 < a.t1)) continue
            if (PlanValidator.compareLayers(byId.getValue(a.layerId), byId.getValue(b.layerId)) < 0) {
                assertTrue("$name: ${a.layerId} below ${b.layerId}", ia > ib) // index 1 is the top
            }
        }
    }

    // ------------------------------------------------------------------ tests

    @Test
    fun everyContractPlanMaps() {
        val plans = PlanFixtures.contractPlans()
        assertTrue(plans.size >= 20)
        for ((name, plan) in plans) {
            val spec = mapper.map(plan)
            checkSpec(name, plan, spec)
        }
    }

    @Test
    fun gridCutsGatingMatchesExpectedActiveOnEveryFrame() {
        val plan = PlanFixtures.contractPlans().getValue("grid_cuts_30fps.json")
        val spec = mapper.map(plan)
        val gating = LayerGating(spec)
        val grid = FrameGrid.of(30)
        val expected = JSONObject(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/grid_cuts_30fps.expected_active.json")))
        val frames = expected.getJSONArray("frames")
        assertEquals(90, frames.length())
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            val k = f.getLong("k")
            val want = (0 until f.getJSONArray("active").length()).map { f.getJSONArray("active").getString(it) }.toSet()
            // V-N1: compositor pts are composition times within -1…+500 µs of P(k).
            for (jitter in listOf(0L, -1L, 250L, 500L)) {
                val pts = grid.platformTimeOfFrame(k) + jitter
                val visible = spec.layerSequences.filter { gating.isVisible(it.index, pts) }
                val got = visible.map { gating.activeAt(it.index, pts)!!.layerId }.toSet()
                assertEquals("k=$k jitter=$jitter", want, got)
                assertFalse("clock band hidden", gating.isVisible(0, pts))
                assertTrue("background shown", gating.isVisible(spec.backgroundIndex, pts))
            }
        }
        // The cuts at k = 31, 32, 61, 62 are sequence boundaries exactly at P(k).
        val boundaries = spec.layerSequences.flatMap { s -> s.items.map { it.startUs } }.toSet()
        for (k in listOf(31L, 32L, 61L, 62L)) assertTrue("boundary at P($k)", grid.platformTimeOfFrame(k) in boundaries)
        // The secondary layer (seq 1) is the top sequence.
        assertEquals(1, spec.sequences[1].slot)
        assertEquals(0, spec.sequences[2].slot)
    }

    @Test
    fun frameGridVectorsAnchorEveryBoundaryAtP() {
        val rates = JSONObject(PlanFixtures.text(PlanFixtures.core("vectors/frame_grid.json"))).getJSONArray("rates")
        var checked = 0
        for (i in 0 until rates.length()) {
            val r = rates.getJSONObject(i)
            val fps = r.getInt("fps")
            val g = FrameGrid.of(fps)
            val frames = r.getJSONArray("frames")
            for (j in 0 until frames.length()) {
                val k = frames.getJSONObject(j).getLong("k")
                if (k == 0L) continue
                val p = frames.getJSONObject(j).getLong("platformTime")
                // A cut at k: gap [0, k), clip [k, k + 2), a second clip [k + 2, k + 3), gap to the end.
                val t = { f: Long -> g.timeOfFrame(f) }
                val layers = listOf(media("it_a#v", 10, 0, t(k), t(k + 2), s0 = 1_000), media("it_b#v", 10, 0, t(k + 2), t(k + 3), s0 = 5_000))
                val pl = plan(layers, t(k + 5), fps = fps)
                val spec = mapper.map(pl)
                checkSpec("fps=$fps k=$k", pl, spec)
                val items = spec.slotSequences.single().items
                assertEquals(listOf(ItemKind.GAP, ItemKind.MEDIA, ItemKind.MEDIA, ItemKind.GAP), items.map { it.kind })
                assertEquals("fps=$fps k=$k: P(k) from the vector", p, items[1].startUs)
                assertEquals(g.platformTimeOfFrame(k + 2), items[2].startUs)
                assertEquals(g.platformTimeOfFrame(k + 3), items[3].startUs)
                assertEquals(pl.durUs, items[3].endUs)
                checked++
            }
        }
        assertTrue(checked >= 70)
    }

    @Test
    fun exportAtAnotherRateAnchorsEdgesOnTheGridRate() {
        // Project at 30 fps exported at 24 fps (gridFps 30): edges at P30(k); images at 24 fps.
        val g = FrameGrid.of(30)
        val layers = listOf(
            media("it_a#v", 10, 0, 0, g.timeOfFrame(31)),
            media("it_b#v", 10, 0, g.timeOfFrame(31), g.timeOfFrame(90)),
            imageLayer("it_i#v", 10010, g.timeOfFrame(32), g.timeOfFrame(62)),
        )
        val pl = plan(layers, g.timeOfFrame(90), fps = 24, gridFps = 30)
        val spec = mapper.map(pl)
        checkSpec("export 24 from 30", pl, spec)
        val slot = spec.slotSequences.single()
        assertEquals(g.platformTimeOfFrame(31), slot.items[0].endUs)
        val imageSeq = spec.layerSequences.first { PlanLayerKind.IMAGE in it.layerKinds }
        assertEquals(g.platformTimeOfFrame(32), imageSeq.items[1].startUs)
        assertEquals(24, imageSeq.items[1].frameRate)
        assertTrue("image above the main slot", imageSeq.index < slot.index)
        // Gating evaluates output frames of the 24 fps grid at timeOfFrame24(k) against 30 fps edges.
        val gating = LayerGating(spec)
        val out = FrameGrid.of(24)
        for (k in 0L until 72L) {
            val t = out.timeOfFrame(k)
            assertEquals("k=$k", t >= g.timeOfFrame(32) && t < g.timeOfFrame(62), gating.isVisible(imageSeq.index, out.platformTimeOfFrame(k)))
        }
    }

    @Test
    fun packingVectorsGiveOneSequencePerSlotInSlotOrder() {
        val cases = JSONObject(PlanFixtures.text(PlanFixtures.core("vectors/packing.json"))).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val inputs = c.getJSONArray("inputs")
            val seqOf = c.getJSONObject("expected").getJSONObject("seq")
            val slotCount = c.getJSONObject("expected").getInt("slotCount")
            if (inputs.length() == 0) continue
            val layers = (0 until inputs.length()).map {
                val x = inputs.getJSONObject(it)
                media(x.getString("id"), x.getInt("z"), seqOf.getInt(x.getString("id")), x.getLong("t0"), x.getLong("t1"))
            }
            val durUs = layers.maxOf { it.t1 }
            val spec = mapper.map(plan(layers, durUs), CompositionMapper.Options(validate = false))
            val name = c.getString("name")
            assertEquals("$name: sequence count = slot count", slotCount, spec.layerSequences.size)
            assertEquals(name, slotCount, spec.slotSequences.size)
            // Slots top → bottom: seq descending from index 1.
            assertEquals(name, (slotCount - 1 downTo 0).toList(), spec.layerSequences.map { it.slot })
            for (l in layers) {
                val s = spec.layerSequences.single { seq -> seq.active.any { it.layerId == l.id } }
                assertEquals("$name: ${l.id}", l.seq, s.slot)
            }
            checkDrawOrder(name, plan(layers, durUs), spec)
        }
    }

    @Test
    fun zOrderPlacesNonMediaLayersBetweenSlots() {
        val g = FrameGrid.of(30)
        val t = { k: Long -> g.timeOfFrame(k) }
        // Main clip (seq 0), an image overlay (z 10010) over it, a PiP clip (z 10020, seq 1) above the image.
        val main = media("it_main#v", 10, 0, 0, t(90))
        val img = imageLayer("it_img#v", 10010, t(10), t(60))
        val pip = media("it_pip#v", 10020, 1, t(30), t(80))
        val pl = plan(listOf(main, img, pip), t(90))
        val spec = mapper.map(pl)
        checkSpec("between slots", pl, spec)
        val order = spec.layerSequences.map { s -> s.active.map { it.layerId }.distinct().single() }
        assertEquals("top → bottom", listOf("it_pip#v", "it_img#v", "it_main#v"), order)

        // A dip-to-black helper solid (z 15) between two clips of slot 0 that it overlaps.
        val a = media("it_a#v", 10, 0, 0, t(45))
        val b = media("it_b#v", 10, 0, t(45), t(90))
        val tx = solid("it_a#tx0", 15, t(40), t(50))
        val pl2 = plan(listOf(a, b, tx), t(90))
        val spec2 = mapper.map(pl2)
        checkSpec("helper solid", pl2, spec2)
        assertEquals(listOf("it_a#tx0"), spec2.sequences[1].active.map { it.layerId })
        assertEquals(0, spec2.sequences[2].slot)
    }

    @Test
    fun aLayerBetweenTwoClipsOfOneSlotIsSplit() {
        val g = FrameGrid.of(30)
        val t = { k: Long -> g.timeOfFrame(k) }
        // A (z 10) and B (z 10020) share slot 0; the image (z 10010) overlaps both: above A, below B.
        val a = media("it_a#v", 10, 0, 0, t(30))
        val b = media("it_b#v", 10020, 0, t(30), t(60))
        val img = imageLayer("it_img#v", 10010, t(15), t(45))
        val pl = plan(listOf(a, b, img), t(60))
        val spec = mapper.map(pl)
        checkSpec("split", pl, spec)
        val pieces = spec.layerSequences.flatMap { s -> s.active.filter { it.layerId == "it_img#v" }.map { s.index to it } }
        assertEquals(2, pieces.size)
        val slotIndex = spec.slotSequences.single().index
        val (aboveIdx, above) = pieces.first { it.second.t0 == t(15) }
        val (belowIdx, below) = pieces.first { it.second.t0 == t(30) }
        assertEquals(t(30), above.t1)
        assertEquals(t(45), below.t1)
        assertTrue("first piece above A's slot", aboveIdx < slotIndex)
        assertTrue("second piece below B's slot", belowIdx > slotIndex)
        // Gating shows exactly one piece per frame.
        val gating = LayerGating(spec)
        for (k in 0L until 60L) {
            val pts = g.platformTimeOfFrame(k)
            val shown = pieces.count { gating.isVisible(it.first, pts) }
            assertEquals("k=$k", if (k in 15L until 45L) 1 else 0, shown)
        }
    }

    @Test
    fun noAudioPlanStillYieldsAnAudioTrack() {
        val plan = PlanFixtures.contractPlans().getValue("no_audio_export.json")
        assertTrue(plan.audio.isEmpty())
        val spec = mapper.map(plan)
        assertTrue(spec.audioSequences.isEmpty())
        assertEquals(TrackTypes.VIDEO_AND_AUDIO, spec.sequences[0].trackTypes)
        assertEquals(plan.durUs, spec.sequences[0].durationUs)
    }

    @Test
    fun audioSegmentsGetIntervalColoursGainPitchAndStream() {
        val g = FrameGrid.of(30)
        val t = { k: Long -> g.timeOfFrame(k) }
        fun seg(id: String, k0: Long, k1: Long, s0: Long, rate: Double = 1.0, pitch: Boolean = true, stream: Int = 0) = AudioSeg(
            id = id, asset = "md_m", stream = stream, t0 = t(k0), t1 = t(k1),
            map = listOf(MapSegment(t(k0), t(k1), s0, s0 + Math.round((t(k1) - t(k0)) * rate))),
            gain = Keyframes.of(t(k0) to 0.0, t(k1) to 2.0), pitch = pitch,
        )
        val audio = listOf(seg("a#a", 0, 45, 0), seg("b#a", 31, 90, 7_000, rate = 2.0, pitch = false), seg("c#a", 45, 61, 0, stream = 1))
        val pl = plan(listOf(media("it_v#v", 10, 0, 0, t(90))), t(90), audio = audio)
        val spec = mapper.map(pl)
        checkSpec("audio", pl, spec)
        assertEquals(2, spec.audioSequences.size)
        val first = spec.audioSequences[0].items.filter { it.kind == ItemKind.AUDIO }
        val second = spec.audioSequences[1].items.filter { it.kind == ItemKind.AUDIO }
        assertEquals(listOf("a#a", "c#a"), first.map { it.segmentId })
        assertEquals(listOf("b#a"), second.map { it.segmentId })
        val b = second.single()
        assertFalse(b.keepPitch)
        assertNotNull(b.speed)
        assertEquals(7_000L, b.clipStartUs) // audio clips at the exact s0 (no ε)
        assertEquals(1, first[1].stream)
        assertEquals(audio[0].gain, first[0].gain)
        assertEquals(TrackTypes.AUDIO, spec.audioSequences[0].trackTypes)
    }

    @Test
    fun fastItemsAreCappedAtTheProjectRateAndSlowOnesAreNot() {
        val g = FrameGrid.of(30)
        val pl = plan(listOf(media("it_f#v", 10, 0, 0, g.timeOfFrame(30), rate = 4.0), media("it_s#v", 10, 0, g.timeOfFrame(30), g.timeOfFrame(90), rate = 0.5)), g.timeOfFrame(90))
        val items = mapper.map(pl).slotSequences.single().items
        assertEquals(30, items[0].frameRate)
        assertNotNull(items[0].speed)
        assertNull(items[1].frameRate)
        assertNotNull(items[1].speed)
    }

    @Test
    fun ruleFrameStartsAndFullSourceDurations() {
        // Sources whose frames sit at round(i·1e6/30) + 400 µs: s0 = 1 s snaps to the frame at 1 000 400 µs
        // (≤ s0 + 500), s0 = 1.0002 s snaps to the same frame, s0 = 0.99 s to the frame before.
        val shifted = FakeSourceTimeline(fps = 30, offsetUs = 400L, durationUs = 8_000_000L)
        val m = CompositionMapper(shifted)
        val g = FrameGrid.of(30)
        for ((s0, want) in listOf(1_000_000L to 1_000_400L, 1_000_200L to 1_000_400L, 990_000L to 967_067L, 0L to 400L)) {
            val pl = plan(listOf(media("it_a#v", 10, 0, 0, g.timeOfFrame(30), s0 = s0)), g.timeOfFrame(30))
            val item = m.map(pl).slotSequences.single().items.single()
            assertEquals("s0=$s0", want, item.clipStartUs)
            assertEquals(8_000_000L, item.sourceDurationUs)
            assertEquals(item.durationUs, media3Duration(item))
        }
    }

    @Test
    fun previewUsesProxiesOnlyWhenAskedAndExportNever() {
        val proxied = video.copy(proxyUri = "file:///proxy.mp4")
        val g = FrameGrid.of(30)
        val base = plan(listOf(media("it_a#v", 10, 0, 0, g.timeOfFrame(30))), g.timeOfFrame(30), target = PlanTarget.PREVIEW)
        val pl = base.copy(assets = base.assets + ("md_v" to proxied))
        assertEquals("file:///proxy.mp4", mapper.map(pl, CompositionMapper.Options(useProxies = true)).slotSequences.single().items.single().uri)
        assertEquals("file:///v.mp4", mapper.map(pl).slotSequences.single().items.single().uri)
        assertEquals("file:///v.mp4", mapper.map(pl.copy(target = PlanTarget.EXPORT), CompositionMapper.Options(useProxies = true)).slotSequences.single().items.single().uri)
    }

    @Test
    fun invalidPlansAreRejectedWithTheLayerId() {
        val f = PlanFixtures.core("${PlanFixtures.CONTRACT}/invalid/seq_overlap.json")
        try {
            mapper.map(PlanFixtures.plan(PlanFixtures.text(f)))
            fail("mapped an invalid plan")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.planInvalid, e.code)
            assertEquals("it_gridD0000001#v", e.itemId)
        }
    }

    @Test
    fun twoThousandItemMapping() {
        val g = FrameGrid.of(30)
        val layers = ArrayList<PlanLayer>()
        val audio = ArrayList<AudioSeg>()
        var k = 0L
        for (i in 0 until 1500) {
            val n = 15L + (i % 7)
            val rate = if (i % 5 == 0) 2.0 else 1.0
            layers += media("it_m$i#v", 10, 0, g.timeOfFrame(k), g.timeOfFrame(k + n), s0 = 1_000L * i, rate = rate)
            if (i % 3 == 0) {
                val t0 = g.timeOfFrame(k)
                val t1 = g.timeOfFrame(k + n)
                audio += AudioSeg("it_m$i#a", "md_v", 0, t0, t1, listOf(MapSegment(t0, t1, 0, t1 - t0)), Keyframes.constant(1.0))
            }
            k += n
        }
        for (i in 0 until 500) {
            val k0 = i * 41L
            layers += if (i % 2 == 0) imageLayer("it_i$i#v", 10010 + 10 * (i % 4), g.timeOfFrame(k0), g.timeOfFrame(k0 + 20))
            else media("it_p$i#v", 10010 + 10 * (i % 4), 1 + (i % 3), g.timeOfFrame(k0), g.timeOfFrame(k0 + 20))
        }
        val pl = plan(layers, g.timeOfFrame(k), audio = audio)
        val noValidate = CompositionMapper.Options(validate = false)
        repeat(3) { mapper.map(pl, noValidate) } // warm-up
        val runs = 5
        val start = System.nanoTime()
        repeat(runs) { mapper.map(pl, noValidate) }
        val ms = (System.nanoTime() - start) / 1e6 / runs
        val total = layers.size + audio.size
        println("AND-08 mapping: $total items (${layers.size} layers, ${audio.size} audio) in %.1f ms (JVM host, fake source timeline)".format(ms))
        assertTrue(total >= 2000)
    }
}
