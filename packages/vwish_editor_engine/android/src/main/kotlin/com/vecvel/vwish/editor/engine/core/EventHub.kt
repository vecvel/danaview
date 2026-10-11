// OWNER: ENG-08
//
// The single multiplexed engine event stream (ARCH §12.6, `EngineEventsApi`). Services emit from any
// thread; the hub delivers on the main thread with the native rate limits of ARCH §12.6 / §18.1:
//
//   clock (per session)               <= 10 Hz
//   progress, exportProgress (per job) <= 4 Hz
//   recorderLevel (per recording)      20 Hz
//
// Rate-limited events are coalesced, never lost at the end: an event inside the interval replaces
// the pending one and is delivered when the interval ends (trailing edge). A terminal job event
// (jobDone, or failure with a jobId) first flushes that job's pending event, then is delivered at
// once. Everything else (preview events, session failures, interruptions, signals, drops, lease
// expiry) passes immediately.
//
// With no listener (before Dart subscribes, during a hot restart, or with the activity destroyed)
// non-rate-limited events are kept in a bounded buffer and replayed to the next listener; stale
// clock/progress/level samples are dropped. `hasListener` tells AND-12 whether a job completed
// detached (D-39).

package com.vecvel.vwish.editor.engine.core

import com.vecvel.vwish.editor.engine.pigeon.ClockMsg
import com.vecvel.vwish.editor.engine.pigeon.DropMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.vwish.editor.engine.pigeon.JobResultMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewEventMsg
import com.vecvel.vwish.editor.engine.pigeon.RecordingInterruptionMsg
import com.vecvel.vwish.editor.engine.pigeon.SignalMsg

/** Where the hub delivers events (the Pigeon event sink of one Flutter engine). Called on main. */
fun interface EngineEventSink {
    /** Delivers one event. */
    fun send(event: EngineEventMsg)
}

/** Native event rate limits in ms between deliveries per (kind, id) (ARCH §12.6). */
data class EventRateLimits(
    val clockMs: Long = 100,
    val progressMs: Long = 250,
    val recorderLevelMs: Long = 50,
)

/** The engine event stream (ARCH §12.6). Thread-safe; delivery happens on [main]. */
class EventHub(
    private val main: MainScheduler,
    private val limits: EventRateLimits = EventRateLimits(),
    private val bufferCapacity: Int = DEFAULT_BUFFER,
) {
    private val sinks = LinkedHashSet<EngineEventSink>()
    private val buffer = ArrayDeque<EngineEventMsg>()
    private val lastSent = HashMap<String, Long>()
    private val pending = HashMap<String, Pending>()

    @Volatile private var listenerCount = 0

    private class Pending(var event: EngineEventMsg, val task: Cancellable)

    /** Whether at least one Dart listener is attached (D-39 detached completion). */
    val hasListener: Boolean get() = listenerCount > 0

    /** Attaches a listener; buffered events are replayed to it. Call on main. */
    fun attach(sink: EngineEventSink) {
        sinks.add(sink)
        listenerCount = sinks.size
        while (buffer.isNotEmpty()) sink.send(buffer.removeFirst())
    }

    /** Detaches a listener. Call on main. */
    fun detach(sink: EngineEventSink) {
        sinks.remove(sink)
        listenerCount = sinks.size
    }

    /** Emits [event] from any thread. */
    fun emit(event: EngineEventMsg) {
        if (main.isCurrentThread()) dispatch(event) else main.execute { dispatch(event) }
    }

    /** A preview clock sample (`timeUs` = timeOfFrame(k), D-35). */
    fun clock(sessionId: String, clock: ClockMsg) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.CLOCK, sessionId = sessionId, clock = clock))

    /** A preview lifecycle event. */
    fun preview(sessionId: String, event: PreviewEventMsg) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.PREVIEW, sessionId = sessionId, previewEvent = event))

    /** A preview session failure (no job id). */
    fun sessionFailure(sessionId: String, error: Throwable) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.FAILURE, sessionId = sessionId, failure = EngineErrors.toFailureMsg(error)))

    /** Job progress 0..1. */
    fun progress(jobId: String, fraction: Double) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.PROGRESS, jobId = jobId, progress = fraction.coerceIn(0.0, 1.0)))

    /** Export progress. */
    fun exportProgress(jobId: String, progress: ExportProgressMsg) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.EXPORT_PROGRESS, jobId = jobId, exportProgress = progress))

    /** A finished job (terminal). */
    fun jobDone(jobId: String, result: JobResultMsg) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.JOB_DONE, jobId = jobId, jobDone = result))

    /** A failed or cancelled job (terminal). */
    fun jobFailed(jobId: String, error: Throwable) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.FAILURE, jobId = jobId, failure = EngineErrors.toFailureMsg(error)))

    /** Recorder input level 0..1. */
    fun recorderLevel(recordingId: String, level: Double) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.RECORDER_LEVEL, jobId = recordingId, recorderLevel = level.coerceIn(0.0, 1.0)))

    /** The recording stopped and kept its file. */
    fun interruption(recordingId: String, kind: RecordingInterruptionMsg) =
        emit(EngineEventMsg(kind = EngineEventKindMsg.INTERRUPTION, jobId = recordingId, interruption = kind))

    /** An engine-wide signal (memory warning, thermal). */
    fun signal(signal: SignalMsg) = emit(EngineEventMsg(kind = EngineEventKindMsg.SIGNAL, signal = signal))

    /** An external drop (D-18). */
    fun drop(drop: DropMsg) = emit(EngineEventMsg(kind = EngineEventKindMsg.DROP, drop = drop))

    /** The background lease is about to expire. */
    fun leaseExpiring(leaseId: String) = emit(EngineEventMsg(kind = EngineEventKindMsg.LEASE_EXPIRING, jobId = leaseId))

    // ---- main thread only below ----

    private fun dispatch(event: EngineEventMsg) {
        val interval = intervalOf(event)
        if (interval == null) {
            if (isTerminal(event)) flushPendingOf(event.jobId)
            deliver(event, bufferIfNoListener = true)
            return
        }
        val key = keyOf(event)
        val now = main.nowMs()
        val waiting = pending[key]
        if (waiting != null) {
            waiting.event = event
            return
        }
        val last = lastSent[key]
        if (last == null || now - last >= interval) {
            lastSent[key] = now
            deliver(event, bufferIfNoListener = false)
            return
        }
        val delay = interval - (now - last)
        lateinit var holder: Pending
        val task = main.postDelayed(Runnable { firePending(key, holder) }, delay)
        holder = Pending(event, task)
        pending[key] = holder
    }

    private fun firePending(key: String, holder: Pending) {
        if (pending[key] !== holder) return
        pending.remove(key)
        lastSent[key] = main.nowMs()
        deliver(holder.event, bufferIfNoListener = false)
    }

    private fun flushPendingOf(jobId: String?) {
        if (jobId == null) return
        val keys = pending.keys.filter { it.endsWith("|$jobId") }
        for (key in keys) {
            val holder = pending.remove(key) ?: continue
            holder.task.cancel()
            deliver(holder.event, bufferIfNoListener = false)
        }
        lastSent.keys.removeAll { it.endsWith("|$jobId") }
    }

    private fun deliver(event: EngineEventMsg, bufferIfNoListener: Boolean) {
        if (sinks.isEmpty()) {
            if (bufferIfNoListener) {
                if (buffer.size >= bufferCapacity) buffer.removeFirst()
                buffer.addLast(event)
            }
            return
        }
        for (sink in sinks.toList()) sink.send(event)
    }

    private fun intervalOf(event: EngineEventMsg): Long? = when (event.kind) {
        EngineEventKindMsg.CLOCK -> limits.clockMs
        EngineEventKindMsg.PROGRESS, EngineEventKindMsg.EXPORT_PROGRESS -> limits.progressMs
        EngineEventKindMsg.RECORDER_LEVEL -> limits.recorderLevelMs
        else -> null
    }

    private fun isTerminal(event: EngineEventMsg): Boolean =
        event.jobId != null && (event.kind == EngineEventKindMsg.JOB_DONE || event.kind == EngineEventKindMsg.FAILURE)

    private fun keyOf(event: EngineEventMsg): String = "${event.kind.name}|${event.sessionId ?: event.jobId ?: ""}"

    companion object {
        /** Events kept while no listener is attached. */
        const val DEFAULT_BUFFER = 256
    }
}
