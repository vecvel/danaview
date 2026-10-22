// OWNER: AND-16
//
// QA-05 soak a #262 (seed 5150, API 35, 034a0d3): right after a reverse completed the preview
// reloaded (its decks started again), an exact seek to frame 392 issued during that reload timed out
// and was acked with frame 0. The engine's deck plan was empty (an export suspension had released
// it); the seek's own plan build was superseded by the structural rebuild of the reverse's new
// rendition, and MultiPlayerEngine.rebuild answered the superseded build at once, so the seek went
// on with the empty plan: frame 392 clamped to 0, frame 0 composed, and the session acked it at the
// exact-seek timeout. The fix answers a superseded build with the newest build's outcome.
//
// The race is made deterministic with the backend's plan-build delay (a slow index of a new
// rendition): the seek's build starts first, the structural patch's build starts 150 ms later
// (the session's debouncer), and the first one finishes while the second still runs.

package com.vecvel.danaview.editor.engine.fallback

import android.util.Log
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.preview.PreviewHarness
import com.vecvel.danaview.editor.engine.preview.PreviewPlans
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.EngineStats
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ContingencyReloadSeekTest {
    private val config = ContingencyPreviewBackend.Config(liveBudget = 6, effectAssets = EffectFixtures.assets, codecSelector = ExactFrames.softwareFirst)

    private fun harness(name: String): PreviewHarness =
        PreviewHarness(name, backend = { ContingencyPreviewBackend(config) }).apply {
            manager.suspendTiers = DeviceTierMsg.entries.toSet()
            open(PreviewQualityMsg.FULL)
        }

    private fun stats(h: PreviewHarness): EngineStats = await { cb -> (h.session.backend as ContingencyPreviewBackend).stats(cb) }

    private val pip = PausedPlans.media("pip#v", 20, 1, 0, PreviewPlans.FRAMES, 150, xf = PlanTransform(cx = 480.0, cy = 270.0, s = 0.3))

    /** Exact seek to [k] and, in the same lane turn, a structural patch: the reload races the seek. */
    private fun seekDuringReload(h: PreviewHarness, k: Long, from: Long): SeekAckMsg = await(60) { cb ->
        h.onPreview {
            h.session.seek(PreviewPlans.grid.timeOfFrame(k), true, cb)
            h.session.applyPatch(PlanWriter.patchJson(PreviewPlans.upsert(from, pip)).toByteArray()) { }
        }
    }

    @Test
    fun aSeekDuringTheReloadAfterAnExportShowsAndAcksItsOwnFrame() {
        harness("and16_reload_seek").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            h.seek(PreviewPlans.grid.timeOfFrame(12))
            h.waitUntil("decks built") { stats(h).deckCount > 0 }
            // An export came and went: the decks and the deck plan are gone until the next seek.
            h.manager.suspendForExport("ex_reload")
            h.waitUntil("decoders released") { stats(h).deckCount == 0 }
            h.manager.resumeAfterExport("ex_reload")
            h.waitUntil("resumed") { h.sync { !h.session.isSuspended } }
            // The new rendition's index is slow: each deck-plan build takes 600 ms.
            config.injectedPlanDelayMs = 600
            val k = 60L
            val t0 = System.nanoTime()
            val ack = seekDuringReload(h, k, from = 1)
            val ms = (System.nanoTime() - t0) / 1_000_000
            Log.i(AND16_TAG, "exact seek during a reload after an export: acked ${ack.displayedFrame} in $ms ms")
            assertEquals("the seek acks its own frame, not one of the plan it replaced", k, ack.displayedFrame)
            assertTrue("acked by the frame, not by the ${ContingencyPreviewBackend.EXACT_SEEK_TIMEOUT_MS} ms timeout ($ms ms)", ms < ContingencyPreviewBackend.EXACT_SEEK_TIMEOUT_MS)
            assertEquals("frame $k on screen", (PreviewPlans.SOURCE_OFFSET + k).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
            config.injectedPlanDelayMs = 0
            // And the session goes on normally on the new plan.
            assertEquals(30L, h.seek(PreviewPlans.grid.timeOfFrame(30)).displayedFrame)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 30).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
        }
    }

    @Test
    fun aSeekDuringAStructuralReloadShowsAndAcksItsOwnFrame() {
        harness("and16_reload_seek_warm").use { h ->
            h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main()), rev = 1))
            h.producer.awaitFrame(0)
            h.seek(PreviewPlans.grid.timeOfFrame(12))
            config.injectedPlanDelayMs = 600
            val ack = seekDuringReload(h, 70, from = 1)
            config.injectedPlanDelayMs = 0
            assertEquals(70L, ack.displayedFrame)
            assertEquals((PreviewPlans.SOURCE_OFFSET + 70).toInt(), FrameBarcode.decode(h.capture(), 640, 360))
        }
    }
}
