// OWNER: AND-19
//
// PrecomposeSpecs on the JVM: the pass compositions are cuts of AND-08's mapped export composition
// at lane boundaries (ARCH D-45(B), §13.3): every lane is drawn exactly once, unchanged and in its
// stacking order (split non-media pieces included); intermediate passes are video only (clock band
// {VIDEO}, no audio sequences) over the background or the previous intermediate; the final pass
// keeps the clock band {VIDEO, AUDIO} and every audio sequence; the intermediate is an ordinary
// MEDIA lane clipped at the rule frame of 0, rate 1, on the P(k) edges, filling the canvas.

package com.vecvel.danaview.editor.engine.precompose

import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.ItemKind
import com.vecvel.danaview.editor.engine.composition.LayerGating
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.SequenceSpec
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import com.vecvel.danaview.editor.engine.export.DecoderBudget
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposePlanner
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposeSpecs
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PrecomposeSpecsTest {
    private val work = File("/data/user/0/app/cache/danaview/editor/work/export-ex_1")

    private fun assertIndexed(spec: CompositionSpec) {
        assertEquals(spec.sequences.indices.toList(), spec.sequences.map { it.index })
    }

    private fun lanesOf(spec: CompositionSpec): List<SequenceSpec> =
        spec.layerSequences.filter { s -> s.active.none { it.layerId.startsWith("precompose:") } }

    /** Builds every pass spec of [plan] under [budget], as PrecomposeExport does. */
    private fun passSpecs(plan: RenderPlan, budget: DecoderBudget): List<CompositionSpec> {
        val padded = PrecomposeSpecs.paddedPlan(plan)
        val passFull = PrecomposePlans.map(padded)
        val finalFull = PrecomposePlans.map(plan)
        val split = PrecomposePlanner.plan(PrecomposePlanner.lanes(passFull), budget)
        val out = ArrayList<CompositionSpec>()
        for (pass in split.passes) {
            val input = if (!pass.readsIntermediate) null else {
                val layer = PrecomposeSpecs.intermediate(plan, pass.number - 1, PrecomposeSpecs.intermediateFile(work, pass.number - 1), 1280, 720, padded.durUs, padded.durUs)
                layer to PrecomposeSpecs.intermediateLane(PrecomposePlans.map(PrecomposeSpecs.intermediatePlan(plan, padded.durUs, layer)))
            }
            out += PrecomposeSpecs.passSpec(passFull, pass.from, pass.to, input?.second, input?.first)
        }
        val last = split.intermediateCount
        val input = if (last == 0) null else {
            val layer = PrecomposeSpecs.intermediate(plan, last, PrecomposeSpecs.intermediateFile(work, last), 1280, 720, plan.durUs, padded.durUs)
            layer to PrecomposeSpecs.intermediateLane(PrecomposePlans.map(PrecomposeSpecs.intermediatePlan(plan, plan.durUs, layer)))
        }
        out += PrecomposeSpecs.finalSpec(finalFull, split.finalFrom, input?.second, input?.first)
        return out
    }

    @Test
    fun intermediatePassesAreVideoOnlyCutsOverTheBackgroundOrThePreviousIntermediate() {
        val plan = PrecomposePlans.overlapping(6, audio = true)
        val specs = passSpecs(plan, DecoderBudget(2, 0))
        assertEquals(5, specs.size)
        val padded = PrecomposePlanner.paddedDurationUs(plan)
        for ((i, s) in specs.dropLast(1).withIndex()) {
            assertIndexed(s)
            val clock = s.sequences.first()
            assertEquals(SequenceKind.CLOCK_BAND, clock.kind)
            assertEquals("pass ${i + 1} clock band is video only", TrackTypes.VIDEO, clock.trackTypes)
            assertTrue("pass ${i + 1} has no audio", s.audioSequences.isEmpty())
            assertEquals(SequenceKind.BACKGROUND, s.sequences.last().kind)
            assertEquals(padded, s.durUs)
            assertTrue(s.sequences.all { it.durationUs == padded })
        }
        // Pass 1: slots 1, 0 over the background; pass 2: slot 2 over pre-1; …
        assertEquals(listOf(1, 0), specs[0].slotSequences.map { it.slot })
        assertEquals(listOf(2, 0), specs[1].slotSequences.map { it.slot })
        assertEquals("precompose:pre-1", specs[1].slotSequences[1].active.single().layerId)
        assertEquals("precompose:pre-3", specs[3].slotSequences[1].active.single().layerId)
        assertNull(specs[0].layers["precompose:pre-1"])
        assertTrue(specs[1].layers.containsKey("precompose:pre-1"))
    }

    @Test
    fun theFinalPassMixesTheAudioOnceOverTheLastIntermediate() {
        val plan = PrecomposePlans.overlapping(6, audio = true)
        val full = PrecomposePlans.map(plan)
        val final = passSpecs(plan, DecoderBudget(2, 0)).last()
        assertIndexed(final)
        assertEquals(TrackTypes.VIDEO_AND_AUDIO, final.sequences.first().trackTypes)
        assertEquals(plan.durUs, final.durUs)
        assertEquals(listOf(5, 0), final.slotSequences.map { it.slot })
        assertEquals("precompose:pre-4", final.slotSequences[1].active.single().layerId)
        val kinds = final.sequences.map { it.kind }
        assertEquals(
            listOf(SequenceKind.CLOCK_BAND, SequenceKind.LAYERS, SequenceKind.LAYERS, SequenceKind.BACKGROUND, SequenceKind.AUDIO),
            kinds,
        )
        assertEquals(full.audioSequences.map { it.items }, final.audioSequences.map { it.items })
    }

    @Test
    fun everyLaneIsDrawnExactlyOnceUnchangedAndInOrder() {
        // Non-media lanes below, between and above the slots; slots with gaps and partial layers.
        val plan = PrecomposePlans.plan(
            listOf(
                PrecomposePlans.Slot(listOf(0L to 60L)),
                PrecomposePlans.Slot(listOf(0L to 20L, 30L to 60L)),
                PrecomposePlans.Slot(listOf(10L to 50L)),
                PrecomposePlans.Slot(listOf(0L to 60L)),
                PrecomposePlans.Slot(listOf(5L to 25L, 40L to 55L)),
            ),
            extra = listOf(
                PrecomposePlans.solid("it_solid#v", 5, 0, 60),
                PrecomposePlans.image("it_logo#v", 25, 10, 45),
                PrecomposePlans.image("it_top#v", 19000, 0, 60),
            ),
        )
        val full = PrecomposePlans.map(plan)
        for (budget in listOf(DecoderBudget(2, 0), DecoderBudget(3, 0), DecoderBudget(10, 5), DecoderBudget(1, 0))) {
            val specs = passSpecs(plan, budget)
            val drawnBottomUp = specs.flatMap { lanesOf(it).asReversed() }
            // Lanes of intermediate passes come from the padded mapping: the same items up to durUs.
            val end = FrameGrid.of(30).frameIndexOf(plan.durUs)
            fun key(s: SequenceSpec) = Triple(
                s.slot,
                s.active,
                s.items.filter { it.startUs < plan.durUs }.map { it.copy(endUs = minOf(it.endUs, plan.durUs), k1 = minOf(it.k1, end)) },
            )
            assertEquals("budget $budget", full.layerSequences.asReversed().map(::key), drawnBottomUp.map(::key))
            for (s in specs) assertIndexed(s)
        }
    }

    @Test
    fun theIntermediateIsARate1MediaLaneOnTheExportGrid() {
        val plan = PrecomposePlans.overlapping(3, frames = 75)
        val padded = PrecomposeSpecs.paddedPlan(plan)
        val file = PrecomposeSpecs.intermediateFile(work, 1)
        assertEquals("pre-1.mp4", file.name)
        val layer = PrecomposeSpecs.intermediate(plan, 1, file, 1280, 720, plan.durUs, padded.durUs)
        assertEquals("file://" + file.absolutePath, layer.asset.uri)
        assertEquals(padded.durUs, layer.asset.durUs)
        assertEquals(0, layer.layer.z)
        assertEquals(0, layer.layer.seq)
        assertNull("base defaults to the canvas", layer.layer.base)
        assertTrue(layer.layer.xf.isIdentity)
        assertTrue(layer.layer.fx.isEmpty)

        // In an intermediate pass: [0, durUs) of the file, then a transparent gap to the padded end.
        val inPass = PrecomposeSpecs.intermediatePlan(plan, padded.durUs, layer)
        assertEquals(emptyList<Any>(), PlanValidator.validate(inPass))
        val lane = PrecomposeSpecs.intermediateLane(PrecomposePlans.map(inPass))
        assertEquals(listOf(ItemKind.MEDIA, ItemKind.GAP), lane.items.map { it.kind })
        val media = lane.items[0]
        assertEquals(0L, media.startUs)
        assertEquals(plan.durUs, media.endUs)
        assertEquals(0L, media.clipStartUs)
        assertEquals(plan.durUs, media.clipEndUs)
        assertNull("rate 1: no speed provider", media.speed)
        assertNull(media.frameRate)
        assertEquals(padded.durUs, lane.items[1].endUs)

        // As PrecomposeExport reads it in pass n >= 2: shown up to the padded end, so the padding
        // frame of every intermediate is the full composite too.
        val readByPass = PrecomposeSpecs.intermediate(plan, 1, file, 1280, 720, padded.durUs, padded.durUs)
        val passPlan = PrecomposeSpecs.intermediatePlan(plan, padded.durUs, readByPass)
        assertEquals(emptyList<Any>(), PlanValidator.validate(passPlan))
        val passLane = PrecomposeSpecs.intermediateLane(PrecomposePlans.map(passPlan))
        assertEquals(listOf(ItemKind.MEDIA), passLane.items.map { it.kind })
        assertEquals(padded.durUs, passLane.items[0].endUs)
        assertEquals(padded.durUs, passLane.items[0].clipEndUs)
        val passSpec = PrecomposeSpecs.passSpec(PrecomposePlans.map(padded), 2, 3, passLane, readByPass)
        val passGating = LayerGating(passSpec)
        val passIndex = passSpec.sequences.single { s -> s.active.any { it.layerId == readByPass.layer.id } }.index
        val grid = FrameGrid.of(30)
        val paddedFrames = grid.frameIndexOf(padded.durUs)
        assertEquals(76L, paddedFrames)
        for (k in 0 until paddedFrames) assertTrue("pass frame $k", passGating.isVisible(passIndex, grid.platformTimeOfFrame(k)))

        // In the final pass: exactly [0, durUs).
        val inFinal = PrecomposeSpecs.intermediateLane(PrecomposePlans.map(PrecomposeSpecs.intermediatePlan(plan, plan.durUs, layer)))
        assertEquals(listOf(ItemKind.MEDIA), inFinal.items.map { it.kind })
        assertEquals(plan.durUs, inFinal.durationUs)

        // Shown on every output frame of the export grid (30 fps) and its parameters fill the canvas.
        val final = PrecomposeSpecs.finalSpec(PrecomposePlans.map(plan), 3, inFinal, layer)
        val gating = LayerGating(final)
        val index = final.sequences.single { s -> s.active.any { it.layerId == layer.layer.id } }.index
        val out = FrameGrid.of(30)
        for (k in 0 until 75L) assertTrue("frame $k", gating.isVisible(index, out.platformTimeOfFrame(k)))
        val snap = ParamSnapshot.of(PrecomposeSpecs.snapshotPlan(plan, layer))
        val params = ParamSnapshot.evaluate(snap.layer(layer.layer.id)!!, snap.plan, 0)
        assertEquals(PlanSize(1280.0, 720.0), params.base)
        assertEquals(640.0, params.xf.cx!!, 0.0)
        assertEquals(360.0, params.xf.cy!!, 0.0)
    }

    @Test
    fun intermediateIdsNeverCollideWithPlanIds() {
        val g = FrameGrid.of(30)
        val clash = PlanLayer(id = "precompose:pre-1", z = 30000, t0 = 0, t1 = g.timeOfFrame(10), kind = com.vecvel.danaview.editor.engine.plan.PlanLayerKind.SOLID, color = -1)
        val plan = PrecomposePlans.overlapping(2, extra = listOf(clash))
        val layer = PrecomposeSpecs.intermediate(plan, 1, File("/x/pre-1.mp4"), 1280, 720, plan.durUs, plan.durUs)
        assertEquals("precompose:pre-1~1", layer.layer.id)
        val snapshot = PrecomposeSpecs.snapshotPlan(plan, layer)
        assertEquals(plan.layers.size + 1, snapshot.layers.map { it.id }.toSet().size)
        assertTrue(snapshot.assets.containsKey(layer.assetId))
    }
}
