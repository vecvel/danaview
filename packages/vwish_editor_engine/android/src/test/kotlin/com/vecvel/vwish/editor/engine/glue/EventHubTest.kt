// OWNER: ENG-08
//
// The multiplexed event stream (ARCH §12.6): main-thread delivery, native rate limits (clock
// <= 10 Hz, progress <= 4 Hz, recorder levels 20 Hz) with trailing delivery, terminal ordering,
// buffering while no Dart listener is attached, and several engines.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineEventSink
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.EventHub
import com.vecvel.vwish.editor.engine.pigeon.ClockMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.vwish.editor.engine.pigeon.JobKindMsg
import com.vecvel.vwish.editor.engine.pigeon.JobResultMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewEventMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalKindMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalMsg
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

    private fun clock(t: Long) = ClockMsg(timeUs = t, playing = true, rate = 1.0, seq = 1)

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
        hub.exportProgress("e1", ExportProgressMsg(ExportPhaseMsg.FINISHING, 0.9, 9, 10, false, false, emptyList()))
        main.drain()
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
}
