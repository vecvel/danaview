// OWNER: ENG-08
//
// The multiplexed event stream (ARCH §12.6): main-thread delivery, native rate limits (clock
// <= 10 Hz, progress <= 4 Hz, recorder levels 20 Hz) with trailing delivery, state-changing samples
// passing at once, route ordering of non-sample events, terminal ordering, buffering while no Dart
// listener is attached, and several engines. The rules match event_router.dart (ENG-01).

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineEventSink
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.EventHub
import com.vecvel.danaview.editor.engine.pigeon.ClockMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportWarningMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordingInterruptionMsg
import com.vecvel.danaview.editor.engine.pigeon.ThermalLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobResultMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalKindMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EventHubTest {
    private val trace = Trace()
    private val main = FakeMain(trace)
    private val hub = EventHub(main)

    private class Collect(private val trace: Trace) : EngineEventSink {
        val events = mutableListOf<EngineEventMsg>()
        val onMain = mutableListOf<Boolean>()
        override fun send(event: EngineEventMsg) {
            events.add(event)
            onMain.add(trace.current == Where.MAIN)
        }
    }

    private fun clock(t: Long, playing: Boolean = true, rate: Double = 1.0, seq: Long = 1) =
        ClockMsg(timeUs = t, playing = playing, rate = rate, seq = seq)

    private fun export(
        fraction: Double,
        phase: ExportPhaseMsg = ExportPhaseMsg.RENDERING,
        backgrounded: Boolean = false,
        paused: Boolean = false,
        warnings: List<ExportWarningMsg> = emptyList(),
    ) = ExportProgressMsg(phase, fraction, (fraction * 100).toLong(), 100, backgrounded, paused, warnings)

    private fun attach(): Collect = Collect(trace).also { sink -> main.onMain { hub.attach(sink) } }

    @Test
    fun eventsFromAnyThreadAreDeliveredOnMain() {
        val sink = attach()
        hub.preview("s1", PreviewEventMsg(kind = PreviewEventKindMsg.FIRST_FRAME))
        assertTrue("nothing before main runs", sink.events.isEmpty())
        main.drain()
        assertEquals(1, sink.events.size)
        assertEquals(listOf(true), sink.onMain)
        assertTrue(hub.hasListener)
    }

    @Test
    fun clockIsLimitedTo10HzPerSessionWithTrailingDelivery() {
        val sink = attach()
        for (i in 0 until 10) {
            hub.clock("s1", clock(i * 16_667L))
            main.drain()
            main.advance(16)
        }
        // 160 ms of ~60 Hz samples: the first at t=0, then the latest sample at t=100 and t=200.
        main.advance(200)
        val times = sink.events.filter { it.kind == EngineEventKindMsg.CLOCK }.map { it.clock!!.timeUs }
        assertEquals(listOf(0L, 6 * 16_667L, 9 * 16_667L), times)
        // Another session has its own budget.
        hub.clock("s2", clock(5))
        main.drain()
        assertEquals("s2", sink.events.last().sessionId)
    }

    @Test
    fun progressIsLimitedTo4HzAndRecorderLevelsTo20Hz() {
        val sink = attach()
        // 1 s of progress every 10 ms.
        for (i in 0 until 100) {
            hub.progress("j1", i / 100.0)
            main.drain()
            main.advance(10)
        }
        main.advance(500)
        val progress = sink.events.filter { it.kind == EngineEventKindMsg.PROGRESS }
        assertTrue("<= 5 deliveries in ~1.25 s, got ${progress.size}", progress.size in 4..6)
        assertEquals(0.99, progress.last().progress!!, 1e-9)

        sink.events.clear()
        for (i in 0 until 100) {
            hub.recorderLevel("r1", 0.5)
            main.drain()
            main.advance(10)
        }
        main.advance(100)
        val levels = sink.events.filter { it.kind == EngineEventKindMsg.RECORDER_LEVEL }
        assertTrue("about 20 per second, got ${levels.size}", levels.size in 19..22)
    }

    @Test
    fun terminalEventFlushesPendingProgressFirst() {
        val sink = attach()
        hub.exportProgress("e1", ExportProgressMsg(ExportPhaseMsg.RENDERING, 0.1, 1, 10, false, false, emptyList()))
        main.drain()
        hub.exportProgress("e1", ExportProgressMsg(ExportPhaseMsg.RENDERING, 0.9, 9, 10, false, false, emptyList()))
        main.drain()
        assertEquals("the second sample is pending", 1, sink.events.size)
        hub.jobDone("e1", JobResultMsg(kind = JobKindMsg.EXPORT))
        main.drain()
        assertEquals(
            listOf(EngineEventKindMsg.EXPORT_PROGRESS, EngineEventKindMsg.EXPORT_PROGRESS, EngineEventKindMsg.JOB_DONE),
            sink.events.map { it.kind },
        )
        assertEquals(0.9, sink.events[1].exportProgress!!.fraction, 1e-9)
        main.advance(1000)
        assertEquals("the flushed event is not delivered twice", 3, sink.events.size)
    }

    @Test
    fun jobFailuresAreScrubbedFailureEvents() {
        val sink = attach()
        hub.jobFailed("j9", EngineException(EngineErrorCode.decodeFailed, "bad frame in /data/x.mp4", mediaFingerprint = "fp"))
        main.drain()
        val failure = sink.events.single().failure!!
        assertEquals("j9", sink.events.single().jobId)
        assertEquals("decodeFailed", failure.code)
        assertEquals("bad frame in <path>", failure.message)
        assertEquals("fp", failure.mediaFingerprint)
    }

    @Test
    fun eventsWithoutListenerAreBufferedExceptStaleSamples() {
        hub.clock("s1", clock(1))
        hub.progress("j1", 0.5)
        hub.signal(SignalMsg(kind = SignalKindMsg.MEMORY_WARNING))
        hub.jobDone("j1", JobResultMsg(kind = JobKindMsg.WAVEFORM))
        main.drain()
        assertFalse(hub.hasListener)
        val sink = attach()
        assertEquals(listOf(EngineEventKindMsg.SIGNAL, EngineEventKindMsg.JOB_DONE), sink.events.map { it.kind })
    }

    @Test
    fun bufferIsBounded() {
        val small = EventHub(main, bufferCapacity = 2)
        repeat(5) { small.leaseExpiring("l$it") }
        main.drain()
        val sink = Collect(trace)
        main.onMain { small.attach(sink) }
        assertEquals(listOf("l3", "l4"), sink.events.map { it.jobId })
    }

    @Test
    fun everyAttachedEngineReceivesEventsAndDetachStops() {
        val a = attach()
        val b = attach()
        hub.signal(SignalMsg(kind = SignalKindMsg.THERMAL))
        main.drain()
        assertEquals(1, a.events.size)
        assertEquals(1, b.events.size)
        main.onMain { hub.detach(a) }
        hub.leaseExpiring("x")
        main.drain()
        assertEquals(1, a.events.size)
        assertEquals(2, b.events.size)
        main.onMain { hub.detach(b) }
        assertFalse(hub.hasListener)
    }

    @Test
    fun stateChangingClockSamplesPassAtOnceAndSupersedeThePendingOne() {
        val sink = attach()
        hub.clock("s1", clock(0))
        main.drain()
        main.advance(20)
        hub.clock("s1", clock(1))
        main.drain()
        assertEquals("same state: coalesced", 1, sink.events.size)

        // Pause inside the interval: delivered at once, the pending playing sample is dropped.
        main.advance(10)
        hub.clock("s1", clock(2, playing = false))
        main.drain()
        assertEquals(listOf(0L, 2L), sink.events.map { it.clock!!.timeUs })

        // A new seq and a new rate also pass at once.
        main.advance(10)
        hub.clock("s1", clock(3, playing = false, seq = 2))
        main.drain()
        main.advance(10)
        hub.clock("s1", clock(4, playing = false, seq = 2, rate = 2.0))
        main.drain()
        assertEquals(listOf(0L, 2L, 3L, 4L), sink.events.map { it.clock!!.timeUs })

        main.advance(1000)
        assertEquals("nothing superseded is delivered later", 4, sink.events.size)
    }

    @Test
    fun stateChangingExportAndProgressSamplesPassAtOnce() {
        val sink = attach()
        hub.exportProgress("e1", export(0.1))
        main.drain()
        main.advance(10)
        hub.exportProgress("e1", export(0.2))
        main.drain()
        assertEquals("same state: coalesced", 1, sink.events.size)

        val warning = ExportWarningMsg(code = "w", message = "m")
        val changes = listOf(
            export(0.3, phase = ExportPhaseMsg.FINISHING),
            export(0.4, phase = ExportPhaseMsg.FINISHING, backgrounded = true),
            export(0.5, phase = ExportPhaseMsg.FINISHING, backgrounded = true, paused = true),
            export(0.6, phase = ExportPhaseMsg.FINISHING, backgrounded = true, paused = true, warnings = listOf(warning)),
            export(1.0, phase = ExportPhaseMsg.FINISHING, backgrounded = true, paused = true, warnings = listOf(warning)),
        )
        for (change in changes) {
            main.advance(10)
            hub.exportProgress("e1", change)
            main.drain()
        }
        assertEquals(listOf(0.1, 0.3, 0.4, 0.5, 0.6, 1.0), sink.events.map { it.exportProgress!!.fraction })
        main.advance(1000)
        assertEquals("the superseded 0.2 sample is never delivered", 6, sink.events.size)

        sink.events.clear()
        hub.progress("j1", 0.5)
        main.drain()
        main.advance(10)
        hub.progress("j1", 0.6)
        main.drain()
        main.advance(10)
        hub.progress("j1", 1.0)
        main.drain()
        assertEquals("reaching 1 passes at once", listOf(0.5, 1.0), sink.events.map { it.progress!! })
        main.advance(1000)
        assertEquals(2, sink.events.size)
    }

    @Test
    fun nonSampleEventsPassAfterThePendingSamplesOfTheirRoute() {
        val sink = attach()
        hub.clock("s1", clock(0))
        hub.clock("s2", clock(0))
        main.drain()
        main.advance(20)
        hub.clock("s1", clock(1))
        hub.clock("s2", clock(1))
        main.drain()
        hub.preview("s1", PreviewEventMsg(kind = PreviewEventKindMsg.FIRST_FRAME))
        main.drain()
        assertEquals(
            listOf("CLOCK s1 0", "CLOCK s2 0", "CLOCK s1 1", "PREVIEW s1"),
            sink.events.map { e -> "${e.kind.name} ${e.sessionId}" + (e.clock?.let { c -> " ${c.timeUs}" } ?: "") },
        )

        // The flushed sample counts as delivered: a same-state sample right after it is rate limited.
        main.advance(10)
        hub.clock("s1", clock(5))
        main.drain()
        assertEquals(4, sink.events.size)

        // The other session's sample stays pending until its interval ends; the flushed one is not repeated.
        main.advance(1000)
        assertEquals(listOf("s2 1", "s1 5"), sink.events.drop(4).map { "${it.sessionId} ${it.clock!!.timeUs}" })

        // Later samples keep their trailing delivery around non-sample events.
        sink.events.clear()
        hub.clock("s1", clock(2))
        main.drain()
        hub.preview("s1", PreviewEventMsg(kind = PreviewEventKindMsg.FIRST_FRAME))
        main.drain()
        main.advance(5)
        hub.clock("s1", clock(3))
        main.drain()
        assertEquals(listOf(EngineEventKindMsg.CLOCK, EngineEventKindMsg.PREVIEW), sink.events.map { it.kind })
        main.advance(1000)
        assertEquals(3L, sink.events.last().clock!!.timeUs)

        sink.events.clear()
        hub.recorderLevel("r1", 0.1)
        main.drain()
        main.advance(5)
        hub.recorderLevel("r1", 0.2)
        main.drain()
        hub.interruption("r1", RecordingInterruptionMsg.INTERRUPTED)
        main.drain()
        assertEquals(
            listOf(EngineEventKindMsg.RECORDER_LEVEL, EngineEventKindMsg.RECORDER_LEVEL, EngineEventKindMsg.INTERRUPTION),
            sink.events.map { it.kind },
        )
        assertEquals(0.2, sink.events[1].recorderLevel!!, 1e-9)
        main.advance(1000)
        assertEquals(3, sink.events.size)
    }

    @Test
    fun onlyTheLatestSignalOfEachKindIsBuffered() {
        repeat(3) { hub.signal(SignalMsg(kind = SignalKindMsg.MEMORY_WARNING)) }
        hub.signal(SignalMsg(kind = SignalKindMsg.THERMAL, thermalLevel = ThermalLevelMsg.FAIR))
        hub.leaseExpiring("l1")
        hub.signal(SignalMsg(kind = SignalKindMsg.THERMAL, thermalLevel = ThermalLevelMsg.SERIOUS))
        main.drain()
        val sink = attach()
        assertEquals(
            listOf("SIGNAL MEMORY_WARNING", "LEASE_EXPIRING null", "SIGNAL THERMAL"),
            sink.events.map { "${it.kind.name} ${it.signal?.kind?.name}" },
        )
        assertEquals(ThermalLevelMsg.SERIOUS, sink.events.last().signal!!.thermalLevel)
    }
}
