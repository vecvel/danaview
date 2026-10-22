// OWNER: AND-10
//
// QA-05 D11 on the JVM: when playback stops for good the quality governor returns auto to the
// requested level (full, or half while thermally capped) and restarts its statistics; pinned levels
// never change; a restart without a stop (play while playing) keeps the level; repeated stops
// report nothing more. The step thresholds themselves are covered on the emulator by
// QualityAndSeekLogicTest.

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QualityGovernorTest {
    private var now = 0L

    private fun governor(q: PreviewQualityMsg) = QualityGovernor(q, clock = { now })

    /** [seconds] of 30 fps playback, every [dropEvery]th frame dropped (0: none); the levels stepped to. */
    private fun play(g: QualityGovernor, seconds: Double, dropEvery: Int): List<QualityLevel> {
        val steps = ArrayList<QualityLevel>()
        for (i in 0 until (seconds * 30).toInt()) {
            now += 33
            g.onFrame(dropped = dropEvery > 0 && i % dropEvery == 0)?.let { steps += it.to }
        }
        return steps
    }

    @Test
    fun aStopAfterDegradingReturnsAutoToTheRequestedLevel() {
        val g = governor(PreviewQualityMsg.AUTO)
        g.onPlaybackStarted()
        assertEquals(listOf(QualityLevel.HALF, QualityLevel.QUARTER), play(g, 4.5, dropEvery = 3))
        assertEquals(
            QualityGovernor.Change(QualityLevel.QUARTER, QualityLevel.FULL, QualityGovernor.Reason.STOP),
            g.onPlaybackStopped(),
        )
        assertEquals(QualityLevel.FULL, g.level)
        assertEquals("the statistics restarted", 0.0, g.windowDropRatio, 0.0)
        assertNull("a second stop reports nothing", g.onPlaybackStopped())
        // The next playback starts at the requested level and steps down with the same thresholds.
        now += 5_000
        g.onPlaybackStarted()
        assertEquals(listOf(QualityLevel.HALF), play(g, 2.0, dropEvery = 3))
    }

    @Test
    fun aStopWhileNotDegradedReportsNothing() {
        val g = governor(PreviewQualityMsg.AUTO)
        g.onPlaybackStarted()
        assertEquals(emptyList<QualityLevel>(), play(g, 3.0, dropEvery = 30))
        assertNull(g.onPlaybackStopped())
        assertEquals(QualityLevel.FULL, g.level)
    }

    @Test
    fun repeatedPausePlayDoesNotReportAgain() {
        val g = governor(PreviewQualityMsg.AUTO)
        g.onPlaybackStarted()
        play(g, 2.0, dropEvery = 3)
        assertEquals(QualityLevel.FULL, g.onPlaybackStopped()?.to)
        repeat(5) {
            g.onPlaybackStarted()
            assertEquals(emptyList<QualityLevel>(), play(g, 0.5, dropEvery = 0))
            assertNull(g.onPlaybackStopped())
        }
    }

    @Test
    fun pinnedLevelsNeverChangeOnStop() {
        for (q in listOf(PreviewQualityMsg.FULL, PreviewQualityMsg.HALF, PreviewQualityMsg.QUARTER)) {
            val g = governor(q)
            g.onPlaybackStarted()
            assertEquals("$q", emptyList<QualityLevel>(), play(g, 5.0, dropEvery = 2))
            assertNull("$q", g.onPlaybackStopped())
            assertEquals(QualityLevel.pinned(q), g.level)
        }
    }

    @Test
    fun aThermalCapReturnsToHalfNotFull() {
        val g = governor(PreviewQualityMsg.AUTO)
        assertEquals(QualityLevel.HALF, g.setThermalStatus(QualityGovernor.THERMAL_STATUS_SEVERE)?.to)
        g.onPlaybackStarted()
        assertEquals(listOf(QualityLevel.QUARTER), play(g, 4.5, dropEvery = 3))
        assertEquals(
            QualityGovernor.Change(QualityLevel.QUARTER, QualityLevel.HALF, QualityGovernor.Reason.STOP),
            g.onPlaybackStopped(),
        )
        // Once the device cools, auto is already at full underneath the cap.
        assertEquals(QualityLevel.FULL, g.setThermalStatus(0)?.to)
    }

    @Test
    fun aRestartWithoutAStopKeepsTheLevel() {
        val g = governor(PreviewQualityMsg.AUTO)
        g.onPlaybackStarted()
        assertEquals(listOf(QualityLevel.HALF), play(g, 2.0, dropEvery = 3))
        // Play while playing (a restart, no stop): the statistics restart, the level stays.
        g.onPlaybackStarted()
        assertEquals(QualityLevel.HALF, g.level)
        assertEquals(0.0, g.windowDropRatio, 0.0)
        assertEquals(emptyList<QualityLevel>(), play(g, 1.0, dropEvery = 0))
        assertEquals(QualityLevel.HALF, g.level)
    }
}
