// OWNER: AND-10
//
// Pure logic of the preview session, run on the emulator (AND-10 owns no JVM test directory):
// - QualityGovernor: render sizes (canvas ÷ 1/2/4, long side capped by maxPreviewLongSide), auto
//   steps full → half → quarter under > 10% dropped frames over 2 s and back after 10 s clean,
//   pinned levels never move under load, thermal SEVERE caps every level at half (ARCH §12.2,
//   §13.2/§13.3, D-43(e)).
// - SeekController: exact acks only on the exact frame, the 500 ms timeout acks the frame
//   displayed, scrubs ack the first frame shown after them, latest wins with followers, failures.
// - SeekMath against core's frame_grid.json vectors (D-35) and `androidSeekMsRounding` = floor.

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QualityAndSeekLogicTest {
    /** A manual scheduler: tasks run when [advance] passes their time, on the test thread. */
    private class ManualScheduler : DebounceScheduler {
        var now = 1_000L
        private val tasks = ArrayList<Triple<Long, Runnable, BooleanArray>>()

        override fun nowMs(): Long = now

        override fun schedule(delayMs: Long, task: Runnable): Cancellable {
            val cancelled = BooleanArray(1)
            tasks += Triple(now + delayMs, task, cancelled)
            return Cancellable { cancelled[0] = true }
        }

        override fun post(task: Runnable) {
            task.run()
        }

        fun advance(ms: Long) {
            val target = now + ms
            while (true) {
                val next = tasks.filter { !it.third[0] && it.first <= target }.minByOrNull { it.first } ?: break
                tasks.remove(next)
                now = next.first
                next.second.run()
            }
            now = target
        }
    }

    // ---- QualityGovernor ----

    @Test
    fun renderSizesFollowTheLevelAndTheTierCap() {
        assertEquals(1280 to 720, QualityGovernor.renderSize(1920, 1080, QualityLevel.FULL, 1280))
        assertEquals(960 to 540, QualityGovernor.renderSize(1920, 1080, QualityLevel.HALF, 1280))
        assertEquals(480 to 270, QualityGovernor.renderSize(1920, 1080, QualityLevel.QUARTER, 1280))
        assertEquals(640 to 360, QualityGovernor.renderSize(640, 360, QualityLevel.FULL, 1920))
        assertEquals(360 to 640, QualityGovernor.renderSize(1080, 1920, QualityLevel.FULL, 640))
        val (w, h) = QualityGovernor.renderSize(1001, 777, QualityLevel.QUARTER, 1920)
        assertTrue(w % 2 == 0 && h % 2 == 0 && w >= 2 && h >= 2)
    }

    @Test
    fun autoStepsDownUnderLoadAndRecoversAfterTenCleanSeconds() {
        var now = 0L
        val g = QualityGovernor(PreviewQualityMsg.AUTO, clock = { now })
        g.onPlaybackStarted()
        assertEquals(QualityLevel.FULL, g.level)
        // 30 fps with every 4th frame dropped (25% > 10%).
        var change: QualityGovernor.Change? = null
        for (i in 0 until 60) {
            now += 33
            change = g.onFrame(dropped = i % 4 == 0) ?: change
        }
        assertEquals(QualityGovernor.Change(QualityLevel.FULL, QualityLevel.HALF, QualityGovernor.Reason.LOAD), change)
        // Still overloaded: one more step after a full window, then quarter stays.
        change = null
        for (i in 0 until 200) {
            now += 33
            change = g.onFrame(dropped = i % 4 == 0) ?: change
        }
        assertEquals(QualityLevel.QUARTER, g.level)
        // Clean playback: back up one level after 10 s, then another after 10 more seconds.
        val ups = ArrayList<QualityGovernor.Change>()
        for (i in 0 until 30 * 25) {
            now += 33
            g.onFrame(dropped = false)?.let { ups += it }
        }
        assertEquals(listOf(QualityLevel.HALF, QualityLevel.FULL), ups.map { it.to })
        assertTrue(ups.all { it.reason == QualityGovernor.Reason.RECOVERY })
    }

    @Test
    fun aFewDropsOrShortWindowsDoNotStepDown() {
        var now = 0L
        val g = QualityGovernor(PreviewQualityMsg.AUTO, clock = { now })
        g.onPlaybackStarted()
        // 1 drop in 30 (3%): fine.
        for (i in 0 until 300) {
            now += 33
            assertNull(g.onFrame(dropped = i % 30 == 0))
        }
        // Fewer frames than minFrames in the window (4 fps, all dropped): no evidence yet.
        val sparse = QualityGovernor(PreviewQualityMsg.AUTO, clock = { now })
        for (i in 0 until 7) {
            now += 250
            assertNull(sparse.onFrame(dropped = true))
        }
    }

    @Test
    fun pinnedLevelsNeverMoveUnderLoadButThermalSevereCapsAtHalf() {
        var now = 0L
        val g = QualityGovernor(PreviewQualityMsg.FULL, clock = { now })
        for (i in 0 until 300) {
            now += 33
            assertNull("pinned full never degrades", g.onFrame(dropped = true))
        }
        assertEquals(QualityLevel.FULL, g.level)
        assertEquals(QualityGovernor.Change(QualityLevel.FULL, QualityLevel.HALF, QualityGovernor.Reason.THERMAL), g.setThermalStatus(3))
        assertNull("moderate keeps the cap until below severe", g.setThermalStatus(3))
        assertEquals(QualityLevel.FULL, g.setThermalStatus(2)?.to)
        // A pinned quarter stays quarter under the thermal cap.
        val q = QualityGovernor(PreviewQualityMsg.QUARTER, clock = { now })
        assertNull(q.setThermalStatus(5))
        assertEquals(QualityLevel.QUARTER, q.level)
        // setRequested switches between auto and pinned.
        assertEquals(QualityLevel.HALF, g.setRequested(PreviewQualityMsg.HALF)?.to)
        assertFalse(g.isAuto)
        assertEquals(QualityLevel.FULL, g.setRequested(PreviewQualityMsg.AUTO)?.to)
        assertTrue(g.isAuto)
    }

    // ---- SeekController ----

    private class Issued(val k: Long, val exact: Boolean, val done: (Result<Unit>) -> Unit)

    @Test
    fun exactSeeksAckOnlyTheExactFrameAndTimeOutToTheFrameShown() {
        val s = ManualScheduler()
        val issued = ArrayList<Issued>()
        val c = SeekController(s) { k, exact, done -> issued += Issued(k, exact, done) }
        val acks = ArrayList<SeekController.Ack>()
        c.request(SeekController.Request(1_000_000, 24, true, 7) { acks += it.getOrThrow() })
        assertEquals(24L, issued.single().k)
        c.onFrameDisplayed(23) // nearest decoded frame first (D-43(e)): no ack
        assertTrue(acks.isEmpty())
        c.onFrameDisplayed(24)
        assertEquals(SeekController.Ack(1_000_000, 24, 24, 7, exactHit = true, latencyMs = 0, timedOut = false), acks.single())
        // Timeout: acked with the frame actually displayed.
        c.request(SeekController.Request(2_000_000, 48, true, 8) { acks += it.getOrThrow() })
        c.onFrameDisplayed(47)
        s.advance(SeekController.EXACT_TIMEOUT_MS)
        val late = acks.last()
        assertEquals(47L, late.displayedFrame)
        assertTrue(late.timedOut)
        assertFalse(late.exactHit)
        assertEquals(1, c.timeouts)
        // A frame arriving after the timeout does not ack twice.
        c.onFrameDisplayed(48)
        assertEquals(2, acks.size)
    }

    @Test
    fun scrubsAckTheFirstFrameShownAndTheLatestRequestWins() {
        val s = ManualScheduler()
        val issued = ArrayList<Issued>()
        val c = SeekController(s) { k, exact, done -> issued += Issued(k, exact, done) }
        val acks = HashMap<Long, SeekController.Ack>()
        fun req(k: Long, exact: Boolean, seq: Long) = c.request(SeekController.Request(k * 41_667, k, exact, seq) { acks[seq] = it.getOrThrow() })
        req(10, false, 1)
        req(20, false, 2) // pending
        req(30, false, 3) // replaces 2; 2 follows 3
        req(40, true, 4) // replaces 3; 2 and 3 follow 4
        assertEquals(listOf(10L), issued.map { it.k })
        c.onFrameDisplayed(9) // any frame acks a scrub
        assertEquals(9L, acks[1]?.displayedFrame)
        assertEquals("only the latest pending seek is issued", listOf(10L, 40L), issued.map { it.k })
        c.onFrameDisplayed(39)
        assertTrue(acks[4] == null)
        c.onFrameDisplayed(40)
        for (seq in 2L..4L) {
            assertEquals(40L, acks[seq]?.displayedFrame)
            assertEquals(4L, acks[seq]?.seq)
        }
        assertFalse(c.isBusy)
    }

    @Test
    fun aFailedSeekFailsItsCallersAndTheNextOneStarts() {
        val s = ManualScheduler()
        val issued = ArrayList<Issued>()
        val c = SeekController(s) { k, exact, done -> issued += Issued(k, exact, done) }
        var failure: Throwable? = null
        var ok: SeekController.Ack? = null
        c.request(SeekController.Request(0, 5, true, 1) { failure = it.exceptionOrNull() })
        c.request(SeekController.Request(0, 6, true, 2) { ok = it.getOrNull() })
        issued[0].done(Result.failure(EngineException(EngineErrorCode.decodeFailed, "x")))
        assertEquals(EngineErrorCode.decodeFailed, (failure as EngineException).code)
        assertEquals(6L, issued[1].k)
        c.onFrameDisplayed(6)
        assertEquals(6L, ok?.displayedFrame)
        // cancelAll fails in-flight and pending seeks.
        var a: Throwable? = null
        var b: Throwable? = null
        c.request(SeekController.Request(0, 7, true, 3) { a = it.exceptionOrNull() })
        c.request(SeekController.Request(0, 8, true, 4) { b = it.exceptionOrNull() })
        c.cancelAll()
        assertEquals(EngineErrorCode.cancelled, (a as EngineException).code)
        assertEquals(EngineErrorCode.cancelled, (b as EngineException).code)
    }

    // ---- SeekMath vs frame_grid.json ----

    @Test
    fun seekMathMatchesTheFrameGridVectors() {
        val json = JSONObject(TestFixtures.open(FixtureTree.CORE, "vectors/frame_grid.json").use { it.readBytes().toString(Charsets.UTF_8) })
        assertEquals(SeekMath.ANDROID_SEEK_MS_ROUNDING, json.getString("androidSeekMsRounding"))
        val rates = json.getJSONArray("rates")
        var checked = 0
        for (i in 0 until rates.length()) {
            val rate = rates.getJSONObject(i)
            val grid = FrameGrid.of(rate.getInt("fps"))
            val frames = rate.getJSONArray("frames")
            for (j in 0 until frames.length()) {
                val f = frames.getJSONObject(j)
                val k = f.getLong("k")
                val t = f.getLong("timeOfFrame")
                val p = f.getLong("platformTime")
                val count = k + 10
                assertEquals("fps ${grid.fps} k $k", k, SeekMath.targetFrame(grid, t, count))
                val idx = f.getJSONObject("frameIndexOf")
                assertEquals(idx.getLong("tMinus1").coerceAtLeast(0), SeekMath.targetFrame(grid, t - 1, count))
                assertEquals(idx.getLong("tPlus1"), SeekMath.targetFrame(grid, t + 1, count))
                assertEquals(k, SeekMath.displayedFrame(grid, p))
                assertEquals(f.getLong("nearestAtPlatformPlusHalf"), SeekMath.displayedFrame(grid, p + rate.getLong("halfFrameMinus1Us")))
                assertEquals(f.getLong("nearestAtPlatformMinusHalf"), SeekMath.displayedFrame(grid, p - rate.getLong("halfFrameMinus1Us")))
                assertEquals(Math.floorDiv(p, 1000L), SeekMath.frameSeekMs(grid, k))
                // A ms seek lands at or before P(k) and within 1 ms of it, so EXACT seeking picks frame k.
                assertTrue(SeekMath.frameSeekMs(grid, k) * 1000 <= p && p - SeekMath.frameSeekMs(grid, k) * 1000 < 1000)
                checked++
            }
            // Clamping at the plan's end and frame counts.
            val dur = grid.timeOfFrame(48)
            assertEquals(48L, SeekMath.frameCount(grid, dur))
            assertEquals(49L, SeekMath.frameCount(grid, dur + 1))
            assertEquals(47L, SeekMath.targetFrame(grid, dur + 5_000_000, 48))
        }
        assertEquals(-2L, SeekMath.seekMs(-1001))
        assertEquals(41L, SeekMath.deckSeekMs(1_041_667, 1_000_000))
        assertTrue(checked > 50)
    }
}
