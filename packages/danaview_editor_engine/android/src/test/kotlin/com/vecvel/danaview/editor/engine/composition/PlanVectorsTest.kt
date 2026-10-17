// OWNER: AND-08
//
// Shared vectors read by the Kotlin side (ARCH §5, §11.2, §11.6; D-35, D-37):
// - frame_grid.json (CORE-02): timeOfFrame, floor time, P(k), frameIndexNearest at every rule;
// - classification.json (CORE-32): structural vs param-only for every case;
// - keyframes.json (API-03): channels evaluated at timeOfFrame(frameIndexNearest(τ)), never at τ,
//   through Keyframes and through ParamSnapshot;
// - gain.json (API-03): the GainProcessor provider is sample-exact at 48 kHz.

package com.vecvel.danaview.editor.engine.composition

import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PatchClass
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanPatches
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlanVectorsTest {
    private fun json(f: java.io.File) = JSONObject(f.readText(Charsets.UTF_8))

    private fun keys(a: JSONArray): Keyframes =
        Keyframes(LongArray(a.length()) { a.getJSONArray(it).getLong(0) }, DoubleArray(a.length()) { a.getJSONArray(it).getDouble(1) })

    @Test
    fun frameGridVectors() {
        val rates = json(PlanFixtures.core("vectors/frame_grid.json")).getJSONArray("rates")
        var checked = 0
        for (i in 0 until rates.length()) {
            val r = rates.getJSONObject(i)
            val fps = r.getInt("fps")
            val g = FrameGrid.of(fps)
            val half = r.getLong("halfFrameMinus1Us")
            val frames = r.getJSONArray("frames")
            for (j in 0 until frames.length()) {
                val f = frames.getJSONObject(j)
                val k = f.getLong("k")
                val at = "fps=$fps k=$k"
                assertEquals(at, f.getLong("timeOfFrame"), g.timeOfFrame(k))
                assertEquals(at, f.getLong("floorTime"), g.floorTimeOfFrame(k))
                assertEquals(at, f.getLong("platformTime"), g.platformTimeOfFrame(k))
                val idx = f.getJSONObject("frameIndexOf")
                assertEquals(at, idx.getLong("t"), g.frameIndexOf(g.timeOfFrame(k)))
                assertEquals(at, idx.getLong("tMinus1"), g.frameIndexOf(g.timeOfFrame(k) - 1))
                assertEquals(at, idx.getLong("tPlus1"), g.frameIndexOf(g.timeOfFrame(k) + 1))
                val nearest = f.getJSONObject("nearest")
                assertEquals(at, nearest.getLong("timeOfFrame"), g.frameIndexNearest(g.timeOfFrame(k)))
                assertEquals(at, nearest.getLong("floorTime"), g.frameIndexNearest(g.floorTimeOfFrame(k)))
                assertEquals(at, nearest.getLong("platformTime"), g.frameIndexNearest(g.platformTimeOfFrame(k)))
                assertEquals(at, f.getLong("nearestAtPlatformPlusHalf"), g.frameIndexNearest(g.platformTimeOfFrame(k) + half))
                assertEquals(at, f.getLong("nearestAtPlatformMinusHalf"), g.frameIndexNearest(g.platformTimeOfFrame(k) - half))
                assertEquals(at, g.timeOfFrame(k), g.frameTimeOf(g.platformTimeOfFrame(k)))
                checked++
            }
        }
        assertTrue(checked >= 70)
    }

    @Test
    fun classificationVectors() {
        val d = json(PlanFixtures.core("render_plans/classification.json"))
        val from = PlanFixtures.plan(d.getJSONObject("from").toString())
        val cases = d.getJSONArray("cases")
        assertTrue(cases.length() >= 30)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val patch = PlanFixtures.patch(c.getJSONObject("patch").toString())
            val expected = if (c.getBoolean("structural")) PatchClass.STRUCTURAL else PatchClass.PARAM_ONLY
            assertEquals(c.getString("name"), expected, PlanPatches.classify(from, patch))
            // The patch applies (atomic, re-sorted) and yields a valid plan at the next revision.
            val next = PlanPatches.apply(from, patch)
            assertEquals(c.getString("name"), patch.to, next.rev)
            assertEquals(c.getString("name"), next.layers.sortedWith(PlanValidator::compareLayers), next.layers)
        }
    }

    @Test
    fun keyframeVectorsEvaluateAtTheFrameTimeOfThePlatformTime() {
        val cases = json(PlanFixtures.engineApi("vectors/keyframes.json")).getJSONArray("cases")
        var samples = 0
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val fps = c.getInt("fps")
            val channel = c.getString("channel")
            val k = keys(c.getJSONArray("keys"))
            val grid = FrameGrid.of(fps)
            val layer = PlanLayer(
                id = "it_vec#v", z = 10, t0 = 0, t1 = grid.timeOfFrame(100_000), kind = PlanLayerKind.SOLID, color = -1,
                anim = mapOf(channel to k),
            )
            val plan = RenderPlan(rev = 1, target = PlanTarget.PREVIEW, canvas = PlanCanvas(1920, 1080, fps), durUs = layer.t1, assets = emptyMap(), layers = listOf(layer), audio = emptyList())
            val snap = ParamSnapshot.of(plan)
            val s = c.getJSONArray("samples")
            for (j in 0 until s.length()) {
                val x = s.getJSONObject(j)
                val tau = x.getLong("tau")
                val at = "${c.getString("name")} k=${x.getLong("k")}"
                assertEquals(at, x.getLong("k"), grid.frameIndexNearest(tau))
                assertEquals(at, x.getLong("t"), grid.timeOfFrame(x.getLong("k")))
                val v = x.getDouble("v")
                assertEquals(at, v, k.valueAt(x.getLong("t")), 2e-9)
                val p = snap.paramsAtPts(layer.id, tau)!!
                val got = when (channel) {
                    "xf.s" -> p.xf.s
                    "xf.op" -> p.xf.op
                    "xf.r" -> p.xf.r
                    "adj.exposure" -> p.adj!!.exposure
                    "adj.saturation" -> p.adj!!.saturation
                    else -> error("channel $channel not covered")
                }
                assertEquals("$at via ParamSnapshot", v, got, 2e-9)
                samples++
            }
        }
        assertTrue(samples >= 30)
    }

    @Test
    fun gainEnvelopeIsSampleExact() {
        val d = json(PlanFixtures.engineApi("vectors/gain.json"))
        val rate = d.getInt("sampleRate")
        assertEquals(48_000, rate)
        val envs = d.getJSONArray("envelopes")
        var samples = 0
        for (i in 0 until envs.length()) {
            val e = envs.getJSONObject(i)
            val provider = KeyframedGainProvider(keys(e.getJSONArray("keys")), 0L)
            val s = e.getJSONArray("samples")
            for (j in 0 until s.length()) {
                val x = s.getJSONObject(j)
                val pos = x.getLong("i")
                val at = "${e.getString("name")} i=$pos"
                assertEquals(at, x.getDouble("tUs"), provider.timeOf(pos, rate), 1e-6)
                assertEquals(at, x.getDouble("g"), provider.gainAt(pos, rate), 1e-9)
                assertEquals(at, x.getDouble("g").toFloat(), provider.getGainFactorAtSamplePosition(pos, rate), 1e-7f)
                samples++
            }
        }
        assertTrue(samples >= 40)
    }
}
