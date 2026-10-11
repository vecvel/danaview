// OWNER: AND-09
//
// The Media3 effects' frame binding and chain shapes (ARCH §13.3 "GL effects", D-35):
// - on grid_cuts_30fps.json (CORE-29) mapped by AND-08's CompositionMapper, every layer
//   sequence's binding returns a layer exactly when expected_active.json lists it at frame k (the
//   early exit otherwise), for pts at P(k), up to 1 µs before the plan edge and +500 µs after
//   (V-N1), and evaluates at timeOfFrame(k), never at the raw pts;
// - an animated opacity is evaluated at timeOfFrame(k) through the live snapshot, and a swapped
//   snapshot (param-only patch) is seen by the next frame;
// - LayerEffectChainFactory gives [look, blur?, place] for media/image items, [place] for solids
//   and gaps, [sprite] for sprite items and nothing for clock/background/audio items.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.composition.CompositionMapper
import com.vecvel.danaview.editor.engine.composition.FakeSourceTimeline
import com.vecvel.danaview.editor.engine.composition.ItemEffectContext
import com.vecvel.danaview.editor.engine.composition.ItemKind
import com.vecvel.danaview.editor.engine.composition.PlanFixtures
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference

class EffectBindingTest {
    private val gridPlan = PlanFixtures.contractPlans().getValue("grid_cuts_30fps.json")

    @Test
    fun bindingGatesExactlyLikeTheExpectedActiveFrames() {
        val spec = CompositionMapper(FakeSourceTimeline()).map(gridPlan)
        val snapshot = AtomicReference(ParamSnapshot.of(gridPlan))
        val grid = FrameGrid.of(gridPlan.canvas.fps)
        val expected = JSONObject(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/grid_cuts_30fps.expected_active.json")))
        val frames = expected.getJSONArray("frames")
        var checked = 0
        for (s in spec.layerSequences) {
            for (item in s.items.filter { it.kind == ItemKind.MEDIA }) {
                val binding = LayerBinding.of(snapshot, s, item.layerId)
                val sequenceBinding = LayerBinding.of(snapshot, s, null)
                for (i in 0 until frames.length()) {
                    val f = frames.getJSONObject(i)
                    val k = f.getLong("k")
                    val active = (0 until f.getJSONArray("active").length()).map { f.getJSONArray("active").getString(it) }.toSet()
                    val inSequence = s.active.any { it.layerId in active }
                    for (pts in listOf(grid.platformTimeOfFrame(k), grid.floorTimeOfFrame(k), grid.platformTimeOfFrame(k) + 500)) {
                        val b = binding.resolve(pts)
                        if (!inSequence) {
                            assertNull("k=$k pts=$pts gated", b)
                        } else {
                            assertEquals("k=$k evaluated at timeOfFrame(k)", grid.timeOfFrame(k), b!!.params.t)
                            assertEquals(item.layerId, b.layer.id)
                            val band = sequenceBinding.resolve(pts)!!
                            assertTrue("k=$k sequence's active layer", band.layer.id in active)
                        }
                        checked++
                    }
                }
            }
        }
        assertTrue("frames checked: $checked", checked >= 90 * 3)
    }

    @Test
    fun animatedChannelsUseTheFrameTimeAndTheLiveSnapshot() {
        val g = FrameGrid.of(30)
        val base = gridPlan.layers.first()
        val layer = base.copy(anim = mapOf("xf.op" to Keyframes.of(0L to 0.0, g.timeOfFrame(30) to 1.0)), xf = PlanTransform())
        val plan = gridPlan.copy(layers = gridPlan.layers.map { if (it.id == base.id) layer else it })
        val snapshot = AtomicReference(ParamSnapshot.of(plan))
        val binding = LayerBinding.of(snapshot, null, layer.id)
        // Frame 10 is stamped at floor(10e6/30) = 333333 µs (1 µs before timeOfFrame(10) = 333334).
        val b = binding.resolve(g.floorTimeOfFrame(10))!!
        assertEquals(g.timeOfFrame(10), b.params.t)
        assertEquals(g.timeOfFrame(10) / g.timeOfFrame(30).toDouble(), b.params.xf.op, 1e-12)
        // A param-only patch swaps the snapshot; the next frame sees it.
        val patched = plan.copy(rev = plan.rev + 1, layers = plan.layers.map { if (it.id == layer.id) it.copy(anim = emptyMap(), xf = PlanTransform(op = 0.25)) else it })
        snapshot.set(snapshot.get().withPlan(patched))
        assertEquals(0.25, binding.resolve(g.floorTimeOfFrame(10))!!.params.xf.op, 0.0)
        assertNull(LayerBinding.NONE.resolve(0))
    }

    @Test
    fun chainShapesPerItemKind() {
        val plan = PlanFixtures.contractPlans().getValue("image_solid_layers.json")
        val spec = CompositionMapper(FakeSourceTimeline()).map(plan)
        val snapshot = AtomicReference(ParamSnapshot.of(plan))
        val factory = LayerEffectChainFactory()
        val seen = HashSet<ItemKind>()
        for (s in spec.sequences) for (item in s.items) {
            val layer = item.layerId?.let { spec.layers[it] }
            val needsBlur = layer != null && ParamSnapshot.needsBlur(layer)
            val effects = factory.videoEffects(ItemEffectContext(spec, s, item, layer, snapshot, needsBlur, layer?.let { ParamSnapshot.maxScale(it) } ?: 1.0))
            val types = effects.map { it.javaClass.simpleName }
            seen += item.kind
            when (item.kind) {
                ItemKind.MEDIA, ItemKind.IMAGE -> {
                    val want = listOfNotNull("LayerLookEffect", if (needsBlur) "SeparableBlurEffect" else null, "LayerPlaceEffect")
                    assertEquals("${item.kind}", want, types)
                }
                ItemKind.SOLID, ItemKind.GAP -> assertEquals("${item.kind}", listOf("LayerPlaceEffect"), types)
                ItemKind.SPRITE -> assertEquals(listOf("SpriteBandEffect"), types)
                else -> assertEquals("${item.kind} has no video effects", emptyList<String>(), types)
            }
            if (s.kind == SequenceKind.LAYERS && item.kind == ItemKind.GAP) {
                assertNull((effects.single() as LayerPlaceEffect).binding.resolve(item.startUs))
            }
        }
        assertTrue("image, solid and background items seen: $seen", seen.containsAll(listOf(ItemKind.IMAGE, ItemKind.SOLID, ItemKind.BACKGROUND)))
    }

    @Test
    fun spritePlansGetSpriteEffects() {
        val plan = PlanFixtures.contractPlans().getValue("sprites_export_reveal.json")
        val spec = CompositionMapper(FakeSourceTimeline()).map(plan)
        val snapshot = AtomicReference(ParamSnapshot.of(plan))
        val sprites = spec.sequences.flatMap { s -> s.items.filter { it.kind == ItemKind.SPRITE }.map { s to it } }
        assertTrue(sprites.isNotEmpty())
        for ((s, item) in sprites) {
            val layer: PlanLayer? = item.layerId?.let { spec.layers[it] }
            val effects = LayerEffectChainFactory().videoEffects(ItemEffectContext(spec, s, item, layer, snapshot, false, 1.0))
            val e = effects.single() as SpriteBandEffect
            val mid = (item.startUs + item.endUs) / 2
            val b = e.binding.resolve(FrameGrid.of(plan.canvas.fps).let { g -> g.platformTimeOfFrame(g.frameIndexOf(mid)) })
            assertEquals(PlanLayerKind.SPRITE, b!!.params.kind)
        }
    }
}
