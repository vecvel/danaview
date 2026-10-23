// OWNER: AND-05
//
// Media job registry (ARCH §12.3, §15, §18.1; BUILD_PLAN AND-05, same contract as iOS IOS-05).
// Runs the jobs `JobsHostApi.startJob` starts: waveform and speechAudio (AND-04), proxy (AND-05),
// freeze (AND-06) and reverse (AND-07). Exports start through ExportHostApi (AND-11), never here.
//
// - Job ids are opaque strings (UUIDs). `start` answers with the id before the job can emit, so
//   Dart always knows the id before its first event. Progress, results and failures are events
//   keyed by the id (`ctx.events.progress / jobDone / jobFailed`); progress never moves backwards
//   and the EventHub keeps it at <= 4 Hz (ARCH §12.6, §18.1).
// - Priorities: interactive > normal (export-blocking) > background; equal priorities run in start
//   order. Concurrency: 1 job on the minimal and low tiers, 2 otherwise (ARCH §15).
// - Pre-emption: a queued interactive job that finds every slot busy stops the lowest running job
//   of lower priority; that job goes back to the queue and restarts later. While an export runs
//   (`setExportActive`, called by AND-11's ExportCoordinator) background jobs and every proxy job
//   are stopped the same way and not started (ARCH §15 'paused while exporting'). Android jobs
//   have no checkpoints: a pre-empted job restarts from the beginning (ARCH §15 'Job
//   interruption': Android jobs keep running under the FGS lease instead of being interrupted by
//   backgrounding).
// - Cancellation: a queued job ends at once, a running job is stopped; either way the job's
//   partial outputs (`.part` files, work/ entries) are deleted and it ends with a `cancelled`
//   failure. Pre-emption is not a cancel: `JobControl.isCancelled` stays false, but
//   `throwIfCancelled()` throws (`interrupted`) and `isStopRequested` turns true, so job bodies
//   stop promptly either way; the registry knows which it was.
// - While any job exists, `DiskCache` treats the engine as active ("Clear editor cache" refused).
//
// Job bodies (`MediaJobBody`) block a worker thread of the registry's pool ("danaview-job-N",
// background priority) and poll their control. Never logs paths or user content.

package com.vecvel.danaview.editor.engine.core

import android.os.Process
import android.util.Log
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.ProxyRegistry
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.JobResultMsg
import com.vecvel.danaview.editor.engine.pigeon.ProxyStatusMsg
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/** Why a running job was asked to stop. */
enum class JobStopReason {
    /** Cancelled by the caller: delete partial output, end with `cancelled`. */
    CANCEL,

    /** Pre-empted by a more important job or by an export: back to the queue, restarted later. */
    PREEMPT,
}

/**
 * The registry's [JobControl]. [isCancelled] is true only for a cancel; [isStopRequested] is true
 * for any stop, and [throwIfCancelled] throws for any stop (`cancelled` or `interrupted`).
 */
class RegistryJobControl(
    override val jobId: String,
    private val progressSink: (Double) -> Unit = {},
) : JobControl {
    private val lock = Any()
    @Volatile private var reason: JobStopReason? = null
    private val handlers = CopyOnWriteArrayList<(JobStopReason) -> Unit>()

    /** Why the job was stopped; null while it may run. */
    val stopReason: JobStopReason? get() = reason

    /** Whether the job must stop now (cancel or pre-emption). */
    val isStopRequested: Boolean get() = reason != null

    override val isCancelled: Boolean get() = reason == JobStopReason.CANCEL

    override fun reportProgress(fraction: Double) = progressSink(fraction)

    override fun throwIfCancelled() {
        when (reason) {
            null -> Unit
            JobStopReason.CANCEL -> throw EngineException(EngineErrorCode.cancelled, "cancelled")
            JobStopReason.PREEMPT -> throw paused()
        }
    }

    /** Runs [handler] when the job is stopped (at once when it already was). Handlers must not block. */
    fun onStop(handler: (JobStopReason) -> Unit) {
        val current = synchronized(lock) {
            reason ?: run {
                handlers.add(handler)
                null
            }
        }
        if (current != null) handler(current)
    }

    /**
     * Stops the job. The first reason wins, except that a cancel overrides a pre-emption. Returns
     * whether the reason changed.
     */
    fun stop(newReason: JobStopReason): Boolean {
        val toRun = synchronized(lock) {
            val current = reason
            if (current == JobStopReason.CANCEL || (current != null && newReason != JobStopReason.CANCEL)) return false
            reason = newReason
            handlers.toList()
        }
        toRun.forEach { it(newReason) }
        return true
    }

    companion object {
        /** The failure a pre-empted body throws (the registry re-queues the job). */
        fun paused(): EngineException = EngineException(EngineErrorCode.interrupted, "job paused", retryable = true)
    }
}

/** Whether the job must stop now: cancelled, or pre-empted when run by the [JobRegistry]. */
val JobControl.isStopRequested: Boolean get() = (this as? RegistryJobControl)?.isStopRequested ?: isCancelled

/** The work of one job. [run] blocks a registry worker thread. */
interface MediaJobBody {
    /** The job kind (the result's kind). */
    val kind: JobKindMsg

    /** Jobs with the same non-null key never run at the same time (proxies of one media). */
    val exclusiveKey: String? get() = null

    /** The media fingerprint of a proxy job (ProxyRegistry status tracking), else null. */
    val proxyFingerprint: String? get() = null

    /** Whether the job is stopped while an export runs whatever its priority (proxies). */
    val pausedDuringExport: Boolean get() = false

    /** Runs (or restarts) the job. Throws an EngineException; stops promptly when [control] says so. */
    fun run(control: RegistryJobControl): JobResultMsg

    /** Deletes partial outputs and work files (after a cancel or a failure). Must not throw. */
    fun cleanUp() = Unit
}

/** Media job registry (ARCH §12.3, §15; AND-05). Called on danaview-jobs; thread-safe. */
class JobRegistry(
    private val ctx: EngineContext,
    /** Jobs at a time; null reads the device tier on first use (1 on minimal/low, 2 otherwise). */
    concurrency: Int? = null,
    /** Where job bodies run (a background thread pool by default; tests inject one). */
    workers: Executor? = null,
    /** Builds the body of a request (tests inject fakes). */
    bodies: ((JobRequestMsg) -> MediaJobBody)? = null,
) {
    /** Job state as seen by tests. */
    enum class State { QUEUED, RUNNING }

    private class Entry(
        val id: String,
        val body: MediaJobBody,
        var priority: JobPriorityMsg,
        val seq: Long,
    ) {
        var state = State.QUEUED
        var control: RegistryJobControl? = null
        var lastProgress = -1.0
        var restarts = 0
    }

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val activeExports = HashSet<String>()
    private var nextSeq = 0L
    private val fixedConcurrency = concurrency
    private val makeBody = bodies ?: ::defaultBody
    private val pool: Executor by lazy { workers ?: Executors.newCachedThreadPool(WorkerThreads) }

    /** Jobs at a time (ARCH §15). */
    val concurrency: Int by lazy { maxOf(1, fixedConcurrency ?: concurrencyFor(ctx.deviceProfile.tier())) }

    /** Starts a job of [request]'s kind (never `export`) and completes with its id. */
    fun start(request: JobRequestMsg, done: Completion<String>) {
        val id = try {
            ctx.requirePaths()
            enqueue(makeBody(request), request.priority, launch = false)
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
            return
        }
        // Reply first: Dart knows the id before the job's first event.
        done.succeed(id)
        synchronized(lock) { pump() }
    }

    /** Queues [body] and returns its job id (the glue path is [start]; tests call this directly). */
    fun enqueue(body: MediaJobBody, priority: JobPriorityMsg, launch: Boolean = true): String {
        val id = UUID.randomUUID().toString()
        DiskCache.beginActivity()
        body.proxyFingerprint?.let { ProxyRegistry.mark(it, ProxyStatusMsg.QUEUED) }
        synchronized(lock) {
            entries[id] = Entry(id, body, priority, nextSeq++)
            Log.i(TAG, "job ${body.kind.name} queued (${priority.name})")
            if (launch) pump()
        }
        return id
    }

    /** Cancels [jobId]; the job ends with a `cancelled` failure event. Unknown ids are ignored. */
    fun cancel(jobId: String) {
        val dropped = synchronized(lock) {
            val entry = entries[jobId] ?: return
            when (entry.state) {
                State.RUNNING -> {
                    entry.control?.stop(JobStopReason.CANCEL)
                    null
                }
                State.QUEUED -> {
                    entries.remove(jobId)
                    entry
                }
            }
        }
        if (dropped != null) {
            safeCleanUp(dropped.body)
            finishFailure(dropped, EngineException(EngineErrorCode.cancelled, "cancelled"))
            synchronized(lock) { pump() }
        }
    }

    /** Changes the priority of [jobId]. Unknown ids are ignored. */
    fun setPriority(jobId: String, priority: JobPriorityMsg) {
        synchronized(lock) {
            val entry = entries[jobId] ?: return
            if (entry.priority == priority) return
            entry.priority = priority
            pump()
        }
    }

    /**
     * Marks export [exportJobId] running ([active] true) or finished. While any export runs,
     * background jobs and proxy jobs are stopped (re-queued) and not started. Called by AND-11's
     * ExportCoordinator when an export starts and when it ends (done, failed or cancelled).
     */
    fun setExportActive(exportJobId: String, active: Boolean) {
        synchronized(lock) {
            val changed = if (active) activeExports.add(exportJobId) else activeExports.remove(exportJobId)
            if (changed) Log.i(TAG, if (active) "export started: pausing background jobs" else "export ended")
            pump()
        }
        releaseHoldWaiters()
    }

    /**
     * Calls [done] once no job held by an export ([setExportActive]) is still running: the stopped
     * jobs have returned from their bodies, so their Transformers and codecs are released (QA-05
     * D9: an export creating its codecs while pre-empted jobs still release theirs). Immediately
     * when none runs. [done] may run on the calling thread or on a job worker, under no lock.
     */
    fun whenHeldJobsStopped(done: () -> Unit) {
        val now = synchronized(lock) {
            if (heldRunning()) {
                holdWaiters += done
                false
            } else {
                true
            }
        }
        if (now) done()
    }

    private val holdWaiters = ArrayList<() -> Unit>()

    private fun heldRunning(): Boolean = entries.values.any { it.state == State.RUNNING && heldByExport(it) }

    /** Releases the [whenHeldJobsStopped] waiters whose condition holds (called outside the lock). */
    private fun releaseHoldWaiters() {
        val ready = synchronized(lock) {
            if (holdWaiters.isEmpty() || heldRunning()) return
            ArrayList(holdWaiters).also { holdWaiters.clear() }
        }
        for (w in ready) {
            try {
                w()
            } catch (t: RuntimeException) {
                Log.w(TAG, "hold waiter failed: ${t.javaClass.simpleName}")
            }
        }
    }

    // ---- introspection (tests) ----

    /** The state of [jobId], null when it is unknown or finished. */
    fun state(jobId: String): State? = synchronized(lock) { entries[jobId]?.state }

    /** Jobs queued or running. */
    val jobCount: Int get() = synchronized(lock) { entries.size }

    /** Jobs running. */
    val runningCount: Int get() = synchronized(lock) { entries.values.count { it.state == State.RUNNING } }

    /** How many times [jobId] was pre-empted and restarted. */
    fun restarts(jobId: String): Int = synchronized(lock) { entries[jobId]?.restarts ?: 0 }

    /** Whether an export is running. */
    val isExportActive: Boolean get() = synchronized(lock) { activeExports.isNotEmpty() }

    // ---- scheduling (under lock) ----

    private fun heldByExport(entry: Entry): Boolean =
        activeExports.isNotEmpty() && (entry.priority == JobPriorityMsg.BACKGROUND || entry.body.pausedDuringExport)

    private fun pump() {
        // Exports stop running background and proxy jobs.
        for (entry in entries.values) {
            if (entry.state == State.RUNNING && heldByExport(entry) && entry.control?.stopReason == null) {
                Log.i(TAG, "job ${entry.body.kind.name} paused by an export")
                entry.control?.stop(JobStopReason.PREEMPT)
            }
        }
        while (true) {
            val running = entries.values.filter { it.state == State.RUNNING }
            val busyKeys = running.mapNotNullTo(HashSet()) { it.body.exclusiveKey }
            val next = entries.values
                .filter { it.state == State.QUEUED && !heldByExport(it) && (it.body.exclusiveKey?.let { k -> k !in busyKeys } ?: true) }
                .minWithOrNull(compareBy<Entry>({ rank(it.priority) }, { it.seq })) ?: return
            if (running.size < concurrency) {
                launch(next)
                continue
            }
            // Interactive jobs pre-empt the lowest running job of lower priority (one at a time).
            if (next.priority == JobPriorityMsg.INTERACTIVE && running.none { it.control?.stopReason == JobStopReason.PREEMPT }) {
                val victim = running
                    .filter { rank(it.priority) > rank(next.priority) && it.control?.stopReason == null }
                    .maxWithOrNull(compareBy<Entry>({ rank(it.priority) }, { it.seq }))
                if (victim != null) {
                    Log.i(TAG, "job ${victim.body.kind.name} pre-empted by an interactive ${next.body.kind.name}")
                    victim.control?.stop(JobStopReason.PREEMPT)
                }
            }
            return
        }
    }

    private fun launch(entry: Entry) {
        val control = RegistryJobControl(entry.id) { fraction -> onProgress(entry, fraction) }
        entry.control = control
        entry.state = State.RUNNING
        entry.body.proxyFingerprint?.let { ProxyRegistry.mark(it, ProxyStatusMsg.RUNNING) }
        try {
            pool.execute {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                val outcome = try {
                    Result.success(entry.body.run(control))
                } catch (t: Throwable) {
                    Result.failure(t)
                }
                completed(entry, control, outcome)
            }
        } catch (t: RuntimeException) {
            // The pool refused the task (process teardown): fail the job.
            entry.control = null
            entries.remove(entry.id)
            finishFailure(entry, EngineErrors.from(t))
        }
    }

    private fun completed(entry: Entry, control: RegistryJobControl, outcome: Result<JobResultMsg>) {
        var failure: EngineException? = null
        var cleanUp = false
        val result = outcome.getOrNull()
        synchronized(lock) {
            entry.control = null
            if (result != null) {
                entries.remove(entry.id)
            } else {
                val error = EngineErrors.from(outcome.exceptionOrNull()!!)
                when (control.stopReason) {
                    JobStopReason.CANCEL -> {
                        entries.remove(entry.id)
                        cleanUp = true
                        failure = EngineException(EngineErrorCode.cancelled, "cancelled")
                    }
                    JobStopReason.PREEMPT -> {
                        entry.state = State.QUEUED
                        entry.restarts++
                        entry.lastProgress = -1.0
                        cleanUp = true
                        entry.body.proxyFingerprint?.let { ProxyRegistry.mark(it, ProxyStatusMsg.QUEUED) }
                        Log.i(TAG, "job ${entry.body.kind.name} paused (pre-empted)")
                    }
                    null -> {
                        entries.remove(entry.id)
                        cleanUp = true
                        // A body that reports `cancelled` without a cancel request is a bug, not a cancel.
                        failure = if (error.code == EngineErrorCode.cancelled) {
                            EngineException(EngineErrorCode.internal, "job stopped without a request")
                        } else {
                            error
                        }
                    }
                }
            }
        }
        if (cleanUp) safeCleanUp(entry.body)
        when {
            result != null -> finishSuccess(entry, result)
            failure != null -> finishFailure(entry, failure)
        }
        synchronized(lock) { pump() }
        releaseHoldWaiters()
    }

    // ---- events ----

    private fun onProgress(entry: Entry, fraction: Double) {
        if (!fraction.isFinite()) return
        val value = fraction.coerceIn(0.0, 1.0)
        synchronized(lock) {
            if (entries[entry.id] !== entry || entry.state != State.RUNNING) return
            if (value <= entry.lastProgress) return
            entry.lastProgress = value
        }
        // The EventHub coalesces per job to <= 4 Hz and always delivers the latest value.
        ctx.events.progress(entry.id, value)
    }

    private fun finishSuccess(entry: Entry, result: JobResultMsg) {
        entry.body.proxyFingerprint?.let { ProxyRegistry.mark(it, null) }
        Log.i(TAG, "job ${entry.body.kind.name} done")
        ctx.events.jobDone(entry.id, result)
        DiskCache.endActivity()
    }

    private fun finishFailure(entry: Entry, failure: EngineException) {
        entry.body.proxyFingerprint?.let {
            ProxyRegistry.mark(it, if (failure.code == EngineErrorCode.cancelled) null else ProxyStatusMsg.FAILED)
        }
        Log.i(TAG, "job ${entry.body.kind.name} ended: ${failure.code.name}")
        ctx.events.jobFailed(entry.id, failure)
        DiskCache.endActivity()
    }

    private fun safeCleanUp(body: MediaJobBody) {
        try {
            body.cleanUp()
        } catch (t: Throwable) {
            Log.w(TAG, "job clean-up failed: ${t.javaClass.simpleName}")
        }
    }

    // ---- bodies ----

    private fun defaultBody(request: JobRequestMsg): MediaJobBody = when (request.kind) {
        JobKindMsg.WAVEFORM -> WaveformBody(ctx, request)
        JobKindMsg.SPEECH_AUDIO -> SpeechAudioBody(ctx, request)
        JobKindMsg.PROXY -> {
            if (request.media.isProxy) throw EngineErrors.invalidArgument("media", "a proxy cannot have a proxy")
            ProxyBody(ctx, request)
        }
        JobKindMsg.FREEZE -> OutputBody(JobKindMsg.FREEZE, request) { control -> JobResultMsg(JobKindMsg.FREEZE, asset = ctx.freezeFrames.run(request, control)) }
        JobKindMsg.REVERSE -> OutputBody(JobKindMsg.REVERSE, request) { control -> JobResultMsg(JobKindMsg.REVERSE, asset = ctx.reverse.run(request, control)) }
        JobKindMsg.EXPORT -> throw EngineErrors.invalidArgument("kind", "exports start through ExportHostApi")
        // INT-06 (D-45): render previews start through preview/render/RenderPreviewJobService (AND-18).
        JobKindMsg.RENDER_PREVIEW -> throw EngineErrors.invalidArgument("kind", "render previews start through the render-preview service")
    }

    /** Waveform peaks (AND-04 WaveformService, cached in waves/). Restarts after a pre-emption. */
    private class WaveformBody(private val ctx: EngineContext, private val request: JobRequestMsg) : MediaJobBody {
        override val kind = JobKindMsg.WAVEFORM
        override val exclusiveKey = "waveform-${request.media.fingerprint}-${request.audioStream ?: 0L}"
        override fun run(control: RegistryJobControl) = JobResultMsg(kind, peaks = ctx.waveforms.peaks(request, control))
    }

    /** 16 kHz speech audio (AND-04 SpeechAudioExtractor, which deletes its own `.part`). */
    private class SpeechAudioBody(private val ctx: EngineContext, private val request: JobRequestMsg) : MediaJobBody {
        override val kind = JobKindMsg.SPEECH_AUDIO
        override fun run(control: RegistryJobControl) = JobResultMsg(kind, speech = ctx.speechAudio.extract(request, control))
        override fun cleanUp() {
            request.outputPath?.let { Paths.normalize(it) }?.let { File(it.path + PART_SUFFIX).delete() }
        }
    }

    /** 540p proxy (AND-05 ProxyJob). One per media at a time; stopped while exporting. */
    private class ProxyBody(private val ctx: EngineContext, private val request: JobRequestMsg) : MediaJobBody {
        override val kind = JobKindMsg.PROXY
        override val exclusiveKey = "proxy-${request.media.fingerprint}"
        override val proxyFingerprint: String = request.media.fingerprint
        override val pausedDuringExport = true
        @Volatile private var jobId: String? = null

        override fun run(control: RegistryJobControl): JobResultMsg {
            jobId = control.jobId
            return JobResultMsg(kind, asset = ctx.proxyJob.run(request, control))
        }

        override fun cleanUp() {
            val id = jobId ?: return
            ctx.pathsOrNull?.let { com.vecvel.danaview.editor.engine.media.ProxyJob.partFile(it, id).delete() }
        }
    }

    /** Freeze frames (AND-06) and reverse renditions (AND-07): the `<outputPath>.part` convention. */
    private class OutputBody(
        override val kind: JobKindMsg,
        private val request: JobRequestMsg,
        private val body: (RegistryJobControl) -> JobResultMsg,
    ) : MediaJobBody {
        override fun run(control: RegistryJobControl) = body(control)
        override fun cleanUp() {
            request.outputPath?.let { Paths.normalize(it) }?.let { File(it.path + PART_SUFFIX).delete() }
        }
    }

    private object WorkerThreads : ThreadFactory {
        private val count = AtomicInteger()
        override fun newThread(r: Runnable): Thread = Thread(r, "danaview-job-${count.incrementAndGet()}").apply { isDaemon = true }
    }

    companion object {
        /** The partial-output suffix of job outputs. */
        const val PART_SUFFIX = ".part"

        /** Jobs at a time per tier (ARCH §15): 1 on minimal and low, 2 otherwise. */
        fun concurrencyFor(tier: DeviceTierMsg): Int = when (tier) {
            DeviceTierMsg.MINIMAL, DeviceTierMsg.LOW -> 1
            DeviceTierMsg.MID, DeviceTierMsg.HIGH -> 2
        }

        /** Scheduling rank: lower runs first. */
        fun rank(priority: JobPriorityMsg): Int = when (priority) {
            JobPriorityMsg.INTERACTIVE -> 0
            JobPriorityMsg.NORMAL -> 1
            JobPriorityMsg.BACKGROUND -> 2
        }

        private const val TAG = EngineContext.TAG
    }
}
