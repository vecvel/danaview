// OWNER: AND-08
//
// ParamSnapshot (ARCH §11.2 Transient, "Patch classification"; D-35): transients merge param
// fields over the current layers (last write wins; empty fx/anim/cmasks clear), never touch timing,
// are dropped by a plan or patch touching their layers and by clearTransient; evaluation maps a
// platform time to timeOfFrame(frameIndexNearest(pts)); base and canvas-mask animation resolve like
// API-03's LayerParamSnapshot.

package com.vecvel.vwish.editor.engine.composition

import com.vecvel.vwish.editor.engine.plan.CanvasMask
import com.vecvel.vwish.editor.engine.plan.FrameGrid
import com.vecvel.vwish.editor.engine.plan.Keyframes
import com.vecvel.vwish.editor.engine.plan.ParamSnapshot
import com.vecvel.vwish.editor.engine.plan.PlanAdjust
import com.vecvel.vwish.editor.engine.plan.PlanAsset
import com.vecvel.vwish.editor.engine.plan.PlanAssetKind
import com.vecvel.vwish.editor.engine.plan.PlanEffects
import com.vecvel.vwish.editor.engine.plan.PlanLayerKind
import com.vecvel.vwish.editor.engine.plan.PlanPatches
import com.vecvel.vwish.editor.engine.plan.PlanSize
import com.vecvel.vwish.editor.engine.plan.PlanTransform
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ParamSnapshotTest {
    private val contract = PlanFixtures.contractPlans()

    @Test
    fun transientsMergeParamFieldsAndClear() {
        val plan = contract.getValue("overlay_pip_chroma_mask.json")
        val pip = plan.layers.first { it.id.startsWith("it_pip") }
        val item = pip.id.substringBefore('#')
        val snap = ParamSnapshot.of(plan)
        val t = PlanFixtures.transient("""{"v":1,"item":"$item","layers":[{"id":"${pip.id}","xf":{"cx":100,"cy":50,"s":2},"fx":{},"t":[0,1]}]}""")
        val merged = snap.withTransient(t)
        val l = merged.layer(pip.id)!!
        assertEquals(PlanTransform(cx = 100.0, cy = 50.0, s = 2.0), l.xf)
        assertEquals("an empty fx clears the layer's effects", PlanEffects.NONE, l.fx)
        assertEquals("timing never changes", pip.t0 to pip.t1, l.t0 to l.t1)
        assertEquals(pip.crop, l.crop)
        assertEquals("the plan is untouched", pip, merged.plan.layer(pip.id))
        // Last write wins; clearTransient restores the plan layer.
        val again = merged.withTransient(PlanFixtures.transient("""{"v":1,"item":"$item","layers":[{"id":"${pip.id}","xf":{"op":0.5}}]}"""))
        assertEquals(PlanTransform(op = 0.5), again.layer(pip.id)!!.xf)
        assertEquals(pip.fx, again.layer(pip.id)!!.fx)
        assertEquals(pip, again.withoutTransient(item).layer(pip.id))
        assertSame(snap, snap.withoutTransient("nothing"))
    }

    @Test
    fun plansAndPatchesTouchingALayerDropItsTransient() {
        val plan = contract.getValue("minimal_preview.json")
        val layer = plan.layers.single()
        val item = layer.id.substringBefore('#')
        val snap = ParamSnapshot.of(plan).withTransient(PlanFixtures.transient("""{"v":1,"item":"$item","layers":[{"id":"${layer.id}","xf":{"s":3}}]}"""))
        // A patch that does not touch the layer keeps the transient.
        val gainOnly = PlanFixtures.patch("""{"v":1,"from":1,"to":2,"audio":{"upsert":[{"id":"it_clip00000001#a","asset":"md_clipA00000001","t":[0,3000000],"map":[[0,3000000,0,3000000]],"gain":[[0,0.5]]}]}}""")
        val kept = snap.withPlan(PlanPatches.apply(plan, gainOnly), emptySet())
        assertEquals(3.0, kept.layer(layer.id)!!.xf.s, 0.0)
        assertEquals(2L, kept.rev)
        // A patch upserting the layer drops it.
        val touching = PlanFixtures.patch("""{"v":1,"from":1,"to":2,"layers":{"upsert":[${com.vecvel.vwish.editor.engine.plan.PlanWriter.planJson(plan).let { org.json.JSONObject(it).getJSONArray("layers").getJSONObject(0) }}]}}""")
        val dropped = snap.withPlan(PlanPatches.apply(plan, touching), touching.layers.upsert.map { it.id }.toSet())
        assertEquals(1.0, dropped.layer(layer.id)!!.xf.s, 0.0)
        assertTrue(dropped.transients.isEmpty())
        // A full plan where the layer changed drops it too.
        val changed = plan.copy(rev = 9, layers = listOf(layer.copy(xf = PlanTransform(op = 0.25))))
        assertTrue(snap.withPlan(changed).transients.isEmpty())
    }

    @Test
    fun evaluationUsesTheFrameTimeOfThePlatformTime() {
        val plan = contract.getValue("anim_every_channel.json")
        val layer = plan.layers.single()
        val snap = ParamSnapshot.of(plan)
        val grid = FrameGrid.of(30)
        for (k in listOf(0L, 1L, 2L, 31L, 32L, 74L, 75L)) {
            val t = grid.timeOfFrame(k)
            val atPts = snap.paramsAtPts(layer.id, grid.floorTimeOfFrame(k))!!
            val atT = snap.paramsAt(layer.id, t)!!
            assertEquals("k=$k", atT, atPts)
            assertEquals(t, atPts.t)
            assertEquals(layer.anim.getValue("xf.cx").valueAt(t), atPts.xf.cx!!, 0.0)
            assertEquals(layer.anim.getValue("adj.tint").valueAt(t), atPts.adj!!.tint, 0.0)
            assertEquals(layer.anim.getValue("mask.r").valueAt(t), atPts.mask!!.r, 0.0)
            assertEquals(layer.anim.getValue("detail.vignette").valueAt(t), atPts.detail!!.vignette, 0.0)
        }
        assertTrue(snap.isActive(layer.id, 0))
        assertFalse(snap.isActive(layer.id, plan.durUs))
        assertNull(snap.paramsAt("missing", 0))
    }

    @Test
    fun basesCentresSpritesAndCanvasMasks() {
        val sprites = contract.getValue("sprites_export_reveal.json")
        val title = sprites.layers.first { it.id.startsWith("it_title") }
        val p = ParamSnapshot.of(sprites).paramsAt(title.id, 1_000_000L)!!
        assertEquals(PlanSize(1080.0, 180.0), p.base)
        assertEquals(7.0, p.reveal!!, 1e-9) // 0 → 14 over [0.5 s, 1.5 s]
        assertEquals(sprites.canvas.h / 2.0 * 0 + 200.0, p.xf.cy!!, 0.0)
        // No base on a sprite: sw/sscale × sh/sscale; on anything else: the canvas.
        val noBase = title.copy(base = null)
        val asset = sprites.assets.getValue(title.asset!!)
        assertEquals(PlanSize(asset.sw!! / asset.sscale!!, asset.sh!! / asset.sscale!!), ParamSnapshot.resolvedBase(noBase, sprites))
        val solid = title.copy(kind = PlanLayerKind.SOLID, base = null)
        assertEquals(PlanSize(sprites.canvas.w.toDouble(), sprites.canvas.h.toDouble()), ParamSnapshot.resolvedBase(solid, sprites))
        // Canvas masks with animated rectangles.
        val m = CanvasMask(cx = 0.0, cy = 0.0, w = 10.0, h = 10.0, anim = mapOf("cx" to Keyframes.of(0L to 0.0, 1_000_000L to 100.0)))
        assertEquals(50.0, ParamSnapshot.evaluateCanvasMask(m, 500_000L).cx, 1e-12)
        assertTrue(ParamSnapshot.evaluateCanvasMask(m, 500_000L).anim.isEmpty())
        // Blur and max scale for the effect chain.
        val blurry = contract.getValue("effects_every_static_key.json").layers.first()
        assertTrue(ParamSnapshot.needsBlur(blurry))
        assertEquals(1.5, ParamSnapshot.maxScale(contract.getValue("anim_every_channel.json").layers.single()), 0.0)
        val plain = blurry.copy(fx = PlanEffects(adj = PlanAdjust(contrast = 0.2)), anim = emptyMap())
        assertFalse(ParamSnapshot.needsBlur(plain))
        assertEquals(PlanAssetKind.SPRITE, asset.kind)
        assertEquals(PlanAsset(PlanAssetKind.IMAGE, "file:///x").fp, "")
    }
}
