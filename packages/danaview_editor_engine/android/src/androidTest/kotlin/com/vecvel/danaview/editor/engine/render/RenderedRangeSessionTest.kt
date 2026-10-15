// OWNER: AND-18
//
// The production entry points of AND-18 on a real PreviewSession and EngineContext (emulator):
// - RenderedRangeHandler.setRenderedRanges installs the session's swap as AND-16's hook, playback
//   enters the ranges, an unknown session answers `internal`, a patch outside every range keeps
//   them, a param patch touching one range drops only that range (within the poll period), the next
//   call restores them, a new plan with a canvas change drops every range (ARCH §12.2), and the
//   binding of a disposed session is dropped;
// - the session's plan (what an export of it reads) never gains a render file (D-45: export plans
//   never reference render files);
// - a session on the stills backend (no range deck) accepts the call and keeps live preview;
// - PowerStateMonitor reports charging and battery saver and emits one `powerStateChanged` signal
//   per change, driven by the emulator's `dumpsys battery` and the `low_power` setting (reset at the
//   end).

package com.vecvel.danaview.editor.engine.render

import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PowerStateMsg
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalKindMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PatchSet
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch
import com.vecvel.danaview.editor.engine.preview.PreviewHarness
import com.vecvel.danaview.editor.engine.preview.StillFramesBackend
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewServices
import com.vecvel.danaview.editor.engine.preview.render.RenderedRangeHandler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RenderedRangeSessionTest {
    private fun config() = ContingencyPreviewBackend.Config(liveBudget = 6, effectAssets = EffectFixtures.assets, codecSelector = ExactFrames.softwareFirst)

    private fun handler(h: PreviewHarness): RenderedRangeHandler =
        RenderPreviewServices.of(h.ctx).renderedRanges.apply { sessions = { h.manager.get(it) } }

    private fun set(h: PreviewHarness, handler: RenderedRangeHandler, msgs: List<RenderedRangeMsg>) =
        h.call<Unit> { s, cb -> handler.setRenderedRanges(s.sessionId, msgs, cb) }

    private fun edges(plan: RenderPlan): List<Long> {
        val g = FrameGrid.of(plan.canvas.fps)
        val d = g.frameIndexOf(plan.durUs)
        return plan.layers.flatMap { listOf(g.frameIndexOf(it.t0), g.frameIndexOf(it.t1)) }.filter { it in 1 until d }.toSortedSet().toList()
    }

    @Test
    fun setRenderedRangesDrivesTheSessionsBackendAndPatchesDropTouchedRanges() {
        PreviewHarness("and18_session", backend = { ContingencyPreviewBackend(config()) }).use { h ->
            h.open(fps = 24)
            val plan = FallbackPlans.gridCut(24)
            h.setPlan(plan)
            val g = FrameGrid.of(24)
            val d = g.frameIndexOf(plan.durUs)
            val e = edges(plan)
            val ranges = listOf(e[0] to e[2], e[3] to e[5])
            val rig = RenderRig(h.engine)
            val msgs = ranges.mapIndexed { i, (a, b) -> rig.msg(a, b, g, rig.render(RangeCut.cut(plan, a, b), "s$i").first) }
            val handler = handler(h)
            set(h, handler, msgs)
            val swap = requireNotNull(handler.swapOf(h.session))
            assertSame("the swap is AND-16's hook", swap, (h.session.backend as ContingencyPreviewBackend).renderedRangeHook)
            assertEquals(ranges.map { it.first }, swap.current.map { it.range.first })
            // Unknown sessions answer `internal`.
            val unknown = runCatching { await<Unit> { cb -> h.onPreview { handler.setRenderedRanges("pv_unknown", msgs, cb) } } }.exceptionOrNull()
            assertEquals(EngineErrorCode.internal, (unknown as EngineException).code)
            // The session's plan, the one an export reads, is unchanged: no render file in it.
            val snapPlan = h.session.snapshot.get().plan
            assertEquals(plan.assets, snapPlan.assets)
            assertTrue(snapPlan.assets.values.none { a -> msgs.any { it.uri.endsWith(a.uri.substringAfterLast('/')) } })
            // Playback enters the ranges (their files play during playback).
            h.seek(0)
            h.play()
            h.waitUntil("playback enters a rendered range", timeoutMs = 30_000) { swap.stats().entered >= 1 }
            h.pause()
            // A patch outside every range (a new solid after the last range) keeps both.
            val outside = PlanLayer(
                id = "x#s", z = 90, t0 = g.timeOfFrame(e[5]), t1 = g.timeOfFrame(d), kind = PlanLayerKind.SOLID,
                color = 0xFF00FF00.toInt(), base = PlanSize(40.0, 40.0),
            )
            h.patch(RenderPlanPatch(from = 1, to = 2, layers = PatchSet(upsert = listOf(outside))))
            Thread.sleep(300)
            assertEquals("a patch outside keeps both ranges", 2, swap.current.size)
            // A param patch of a layer inside the first range only drops that range.
            val r0 = ranges[0]
            val inner = plan.layers.first { l ->
                val a = g.frameIndexOf(l.t0)
                val b = g.frameIndexOf(l.t1)
                a < r0.second && r0.first < b && !(a < ranges[1].second && ranges[1].first < b)
            }
            val t0 = System.nanoTime()
            h.patch(RenderPlanPatch(from = 2, to = 3, layers = PatchSet(upsert = listOf(inner.copy(xf = inner.xf.copy(r = 10.0))))))
            h.waitUntil("the touched range is dropped", timeoutMs = 2_000) { swap.current.size == 1 }
            val dropMs = (System.nanoTime() - t0) / 1e6
            assertEquals(ranges[1].first, swap.current.single().range.first)
            log18("session: param patch of ${inner.id} dropped range $r0 in %.1f ms (ack + poll, emulator)".format(dropMs))
            // The next call restores both; a new plan with another canvas colour drops every range.
            set(h, handler, msgs)
            assertEquals(2, swap.current.size)
            val plan4 = h.session.snapshot.get().plan.let { it.copy(rev = 4, canvas = it.canvas.copy(bg = 0xFF102030.toInt())) }
            h.setPlan(plan4)
            h.waitUntil("a canvas change drops every range", timeoutMs = 2_000) { swap.isEmpty }
            assertEquals(3, swap.stats().dropped)
            // A disposed session's binding is forgotten: the handler keeps no session alive.
            set(h, handler, msgs)
            assertEquals(1, handler.bindingCount)
            await<Unit> { cb -> h.onPreview { h.session.dispose(cb) } }
            h.waitUntil("the binding of a disposed session is dropped", timeoutMs = 3_000) { handler.bindingCount == 0 }
        }
    }

    @Test
    fun aSessionWithoutARangeDeckKeepsLivePreview() {
        PreviewHarness("and18_stills", backend = { StillFramesBackend() }).use { h ->
            h.open(fps = 24)
            val plan = FallbackPlans.gridCut(24)
            h.setPlan(plan)
            val handler = handler(h)
            val rig = RenderRig(h.engine)
            set(h, handler, listOf(rig.msg(10, 20, FrameGrid.of(24), rig.output("never"))))
            assertNull("no swap on the stills backend", handler.swapOf(h.session))
        }
    }

    private fun shell(cmd: String): String {
        val pfd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(cmd)
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { String(it.readBytes()) }
    }

    @Test
    fun powerStateFollowsChargingAndBatterySaver() {
        val engine = FreezeEngine("and18_power")
        val power = RenderPreviewServices.of(engine.ctx).power
        fun state(): PowerStateMsg = await { cb -> InstrumentationRegistry.getInstrumentation().runOnMainSync { power.powerState(cb) } }
        fun signals(): List<PowerStateMsg> = synchronized(engine.events) {
            engine.events.filter { it.kind == EngineEventKindMsg.SIGNAL && it.signal?.kind == SignalKindMsg.POWER_STATE_CHANGED }.mapNotNull { it.signal?.powerState }
        }
        fun waitSignal(what: String, cond: (PowerStateMsg) -> Boolean): PowerStateMsg {
            val deadline = System.currentTimeMillis() + 15_000
            while (System.currentTimeMillis() < deadline) {
                signals().lastOrNull()?.takeIf(cond)?.let { return it }
                Thread.sleep(50)
            }
            throw AssertionError("no powerStateChanged signal: $what (signals ${signals()})")
        }
        try {
            shell("settings put global low_power 0")
            shell("dumpsys battery set ac 1")
            shell("dumpsys battery set status 2")
            Thread.sleep(500)
            val s0 = state()
            assertTrue("charging on AC", s0.charging)
            assertFalse(s0.lowPowerMode)
            assertTrue(power.isWatching)
            shell("dumpsys battery unplug")
            shell("dumpsys battery set status 3")
            val unplugged = waitSignal("unplugged") { !it.charging }
            assertFalse(unplugged.lowPowerMode)
            shell("settings put global low_power 1")
            val saver = waitSignal("battery saver on") { it.lowPowerMode }
            assertFalse(saver.charging)
            assertEquals(PowerStateMsg(charging = false, lowPowerMode = true), state())
            shell("settings put global low_power 0")
            waitSignal("battery saver off") { !it.lowPowerMode && !it.charging }
            // One signal per change: no two consecutive signals carry the same state.
            val all = signals()
            log18("power signals (emulator): $all")
            assertTrue("one signal per change: $all", all.zipWithNext().none { (a, b) -> a == b })
        } finally {
            shell("settings put global low_power 0")
            shell("dumpsys battery reset")
            power.stop()
            engine.close()
        }
    }
}
