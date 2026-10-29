// OWNER: AND-16
//
// QA-02 s18 close stall (2026-10-22, Pixel_API_29_2GB): at the second close the reopened editor's
// four deck players were never released. The native side was cleared (the Dart close never reached
// PreviewSession.dispose, see the s18_close_stall evidence), and these tests pin the owner's rule
// for the native half: a preview release completes promptly, releases every deck and never blocks
// the platform main thread, whatever is in flight when the close comes:
//
// - an exact seek issued in the same lane turn as the dispose (the seek is in flight);
// - a paused param patch whose render is deferred behind that seek (QA-05 D10);
// - an export suspension in flight (QA-05 D9; its `released` callback must still run);
// - playback.
//
// Each case runs on a fresh session REPEATS times (close → reopen → close, like s18). "Released"
// is checked on danaview-gl: the backend's engine is gone (its decks were released before), and
// the session left the manager. The main thread is probed every 10 ms while the dispose runs.

package com.vecvel.danaview.editor.engine.fallback

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.PausedPlans
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.preview.PreviewHarness
import com.vecvel.danaview.editor.engine.preview.PreviewPlans
import com.vecvel.danaview.editor.engine.preview.PreviewSession
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.EngineStats
import com.vecvel.danaview.editor.engine.harness.PerfGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class ContingencyCloseTest {
    private fun harness(name: String): PreviewHarness =
        PreviewHarness(name, backend = {
            ContingencyPreviewBackend(
                ContingencyPreviewBackend.Config(liveBudget = 6, effectAssets = EffectFixtures.assets, codecSelector = ExactFrames.softwareFirst),
            )
        }).apply {
            manager.suspendTiers = DeviceTierMsg.entries.toSet()
            open(PreviewQualityMsg.FULL)
        }

    private fun backend(h: PreviewHarness) = h.session.backend as ContingencyPreviewBackend

    private fun stats(h: PreviewHarness): EngineStats = await { cb -> backend(h).stats(cb) }

    /** A main layer and a PiP: two video slots, so the engine holds several decks. */
    private fun prepare(h: PreviewHarness) {
        val pip = PausedPlans.media("pip#v", 20, 1, 0, PreviewPlans.FRAMES, 150, xf = PlanTransform(cx = 480.0, cy = 270.0, s = 0.3))
        h.setPlan(PreviewPlans.plan(listOf(PreviewPlans.main(), pip), rev = 1))
        h.producer.awaitFrame(0)
        h.seek(PreviewPlans.grid.timeOfFrame(12))
        h.waitUntil("decks built") { stats(h).deckCount > 0 }
    }

    private class Closed(val disposeMs: Long, val mainStallMs: Long)

    /**
     * Runs [inFlight] and then `dispose` in one turn of danaview-preview and waits for the dispose;
     * returns how long it took and the longest main-thread stall seen meanwhile.
     */
    private fun disposeWith(h: PreviewHarness, inFlight: (PreviewSession) -> Unit): Closed {
        val main = Handler(Looper.getMainLooper())
        val worst = AtomicLong()
        val done = CountDownLatch(1)
        val probing = Thread {
            while (done.count > 0) {
                val posted = SystemClock.uptimeMillis()
                val ran = CountDownLatch(1)
                main.post { ran.countDown() }
                if (!ran.await(DISPOSE_BOUND_MS, TimeUnit.MILLISECONDS)) {
                    worst.set(DISPOSE_BOUND_MS)
                    return@Thread
                }
                worst.updateAndGet { maxOf(it, SystemClock.uptimeMillis() - posted) }
                Thread.sleep(10)
            }
        }.apply { start() }
        val t0 = SystemClock.uptimeMillis()
        var result: Result<Unit>? = null
        h.onPreview {
            inFlight(h.session)
            h.session.dispose { r ->
                result = r
                done.countDown()
            }
        }
        assertTrue("dispose completed within ${PerfGate.boundMs(DISPOSE_BOUND_MS)} ms (${PerfGate.mode})", done.await(PerfGate.boundMs(DISPOSE_BOUND_MS), TimeUnit.MILLISECONDS))
        val ms = SystemClock.uptimeMillis() - t0
        probing.join(DISPOSE_BOUND_MS)
        assertTrue("dispose succeeded: $result", result!!.isSuccess)
        return Closed(ms, worst.get())
    }

    /** Every deck is released: the engine is gone on danaview-gl and the session left the manager. */
    private fun assertReleased(h: PreviewHarness, c: Closed, what: String) {
        val engine = runCatching { stats(h) }.exceptionOrNull()
        assertTrue("$what: the engine (and its decks) released", engine != null && EngineErrors.from(engine).code == EngineErrorCode.cancelled)
        assertTrue("$what: the session left the manager", h.manager.openSessions.isEmpty())
        val stallBound = PerfGate.boundMs(MAIN_STALL_BOUND_MS)
        assertTrue("$what: the main thread never waited ${c.mainStallMs} ms (<= $stallBound, ${PerfGate.mode})", c.mainStallMs <= stallBound)
        Log.i(AND16_TAG, "close with $what: dispose ${c.disposeMs} ms, longest main-thread wait ${c.mainStallMs} ms")
    }

    private fun repeatClose(name: String, what: String, inFlight: (PreviewHarness, PreviewSession) -> Unit) {
        repeat(REPEATS) { i ->
            harness("${name}_$i").use { h ->
                prepare(h)
                val c = disposeWith(h) { s -> inFlight(h, s) }
                assertReleased(h, c, "$what (#$i)")
            }
        }
    }

    @Test
    fun aCloseBehindAnExactSeekReleasesEveryDeck() {
        repeatClose("and16_close_seek", "an exact seek in flight") { _, s ->
            s.seek(PreviewPlans.grid.timeOfFrame(70), true) { }
        }
    }

    @Test
    fun aCloseBehindARenderDeferredByASeekReleasesEveryDeck() {
        repeatClose("and16_close_deferred", "a paused render deferred behind a seek") { _, s ->
            s.seek(PreviewPlans.grid.timeOfFrame(40), true) { }
            // Paused patch while the seek is busy: its render waits for the seek's ack (D10).
            s.applyPatch(PlanWriter.patchJson(PreviewPlans.upsert(1, PreviewPlans.box(cx = 300.0))).toByteArray()) { }
            s.seek(PreviewPlans.grid.timeOfFrame(80), true) { }
        }
    }

    @Test
    fun aCloseDuringAnExportSuspensionReleasesEveryDeckAndTheExportGoesOn() {
        repeat(REPEATS) { i ->
            harness("and16_close_suspend_$i").use { h ->
                prepare(h)
                val released = CountDownLatch(1)
                val c = disposeWith(h) { s ->
                    s.seek(PreviewPlans.grid.timeOfFrame(50), true) { }
                    h.manager.suspendForExport("job_close_$i") { released.countDown() }
                }
                assertReleased(h, c, "an export suspension in flight (#$i)")
                assertTrue("the export's wait for the preview decoders ends", released.await(PerfGate.boundMs(DISPOSE_BOUND_MS), TimeUnit.MILLISECONDS))
                h.manager.resumeAfterExport("job_close_$i")
            }
        }
    }

    @Test
    fun aCloseDuringPlaybackReleasesEveryDeck() {
        repeatClose("and16_close_play", "playback") { _, s ->
            s.play(null) { }
        }
    }

    @Test
    fun aCloseRightAfterTheOpenSeekReleasesEveryDeck() {
        // s18's reopen: the editor seeks to the saved playhead and reads the frame, then closes.
        repeat(REPEATS) { i ->
            harness("and16_close_reopen_$i").use { h ->
                prepare(h)
                assertEquals(77L, h.seek(PreviewPlans.grid.timeOfFrame(77)).displayedFrame)
                h.capture()
                val c = disposeWith(h) { }
                assertReleased(h, c, "a close after the reopen's seek and capture (#$i)")
            }
        }
    }

    private companion object {
        const val REPEATS = 3

        /** A release completes well inside the Dart close's 3 s per-step bound. */
        const val DISPOSE_BOUND_MS = 3_000L

        /** The surface hand-off contract: the main thread never waits longer (AND-10). */
        const val MAIN_STALL_BOUND_MS = 500L
    }
}
