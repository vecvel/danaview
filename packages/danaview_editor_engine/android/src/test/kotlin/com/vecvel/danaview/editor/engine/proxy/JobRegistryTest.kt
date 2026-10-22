// OWNER: AND-05
//
// JobRegistry on the JVM (BUILD_PLAN AND-05, same contract as iOS IOS-05): ids answered before the
// first event, priorities and start order, concurrency, exclusive keys, pre-emption by interactive
// jobs, background and proxy jobs paused while a (fake) export coordinator runs an export,
// cancellation of queued and running jobs with clean-up, monotonic progress, typed failures and
// the DiskCache activity count. Job bodies run on a manual executor, so every interleaving is
// deterministic; events go through the real EventHub on a fake main thread.

package com.vecvel.danaview.editor.engine.proxy

import android.content.ContextWrapper
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobRegistry
import com.vecvel.danaview.editor.engine.core.JobStopReason
import com.vecvel.danaview.editor.engine.core.MediaJobBody
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.RegistryJobControl
import com.vecvel.danaview.editor.engine.core.isStopRequested
import com.vecvel.danaview.editor.engine.glue.FakeThreads
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.ProxyRegistry
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.JobResultMsg
import com.vecvel.danaview.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.Executor

/** Runs submitted tasks only when the test says so. */
class ManualExecutor : Executor {
    private val queue = ArrayDeque<Runnable>()

    override fun execute(command: Runnable) {
        queue.addLast(command)
    }

    val pending: Int get() = queue.size

    /** Runs the oldest submitted task. */
    fun runNext() = queue.removeFirst().run()

    /** Runs tasks until none is left. */
    fun runAll() {
        while (queue.isNotEmpty()) runNext()
    }
}

/**
 * A scripted job body. [script] runs on the executor; by default it reports progress and returns.
 * Like the real services it stops when its control asks (cancel or pre-emption).
 */
class FakeBody(
    val name: String,
    override val kind: JobKindMsg = JobKindMsg.WAVEFORM,
    override val exclusiveKey: String? = null,
    override val proxyFingerprint: String? = null,
    override val pausedDuringExport: Boolean = false,
    private val log: MutableList<String>,
    var script: (RegistryJobControl) -> Unit = {},
) : MediaJobBody {
    var runs = 0
    var cleanUps = 0

    override fun run(control: RegistryJobControl): JobResultMsg {
        runs++
        log.add("run $name")
        control.throwIfCancelled()
        script(control)
        control.throwIfCancelled()
        return JobResultMsg(kind, asset = GeneratedAssetMsg(path = "/out/$name", sizeBytes = 1))
    }

    override fun cleanUp() {
        cleanUps++
        log.add("cleanUp $name")
    }
}

/**
 * A stand-in for AND-11's ExportCoordinator: it tells the registry when an export starts and ends,
 * exactly as the real coordinator must (`JobRegistry.setExportActive`).
 */
class FakeExportCoordinator(private val jobs: JobRegistry) {
    private var next = 0

    fun startExport(): String = "export-${next++}".also { jobs.setExportActive(it, true) }

    fun finishExport(id: String) = jobs.setExportActive(id, false)
}

class JobRegistryTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val fake = FakeThreads()
    private val ctx = EngineContext(ContextWrapper(null), fake.threads)
    private val executor = ManualExecutor()
    private val log = mutableListOf<String>()
    private val events = mutableListOf<EngineEventMsg>()
    private lateinit var paths: Paths

    @Before
    fun setUp() {
        val root = temp.newFolder("app")
        paths = Paths.fromDart(File(root, "cache/danaview/editor").absolutePath, File(root, "files/danaview/editor").absolutePath)
        ctx.installRoots(paths)
        fake.main.onMain { ctx.events.attach { events.add(it) } }
    }

    @After
    fun tearDown() {
        while (DiskCache.isActive) DiskCache.endActivity()
    }

    private fun registry(concurrency: Int = 1, bodies: ((JobRequestMsg) -> MediaJobBody)? = null) =
        JobRegistry(ctx, concurrency = concurrency, workers = executor, bodies = bodies)

    private fun body(name: String, kind: JobKindMsg = JobKindMsg.WAVEFORM, key: String? = null, proxy: String? = null) =
        FakeBody(name, kind, key, proxy, pausedDuringExport = proxy != null, log = log)

    /** Delivers the events emitted so far (fake main thread, rate limits elapsed). */
    private fun deliver(): List<EngineEventMsg> {
        fake.main.advance(1_000)
        return events
    }

    private fun terminal(jobId: String): EngineEventMsg? =
        deliver().lastOrNull { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }

    private fun request(kind: JobKindMsg, priority: JobPriorityMsg = JobPriorityMsg.NORMAL, isProxy: Boolean = false) =
        JobRequestMsg(kind = kind, media = ResolvedMediaMsg(uri = "file:///m.mp4", fingerprint = "fp", isProxy = isProxy), priority = priority)

    @Test
    fun startAnswersTheIdBeforeAnyEventOfTheJob() {
        val b = body("a")
        val jobs = registry(bodies = { b })
        val replies = mutableListOf<Result<String>>()
        jobs.start(request(JobKindMsg.WAVEFORM)) { result ->
            replies.add(result)
            // The job has not run (nor emitted) when the id is answered.
            assertEquals(0, b.runs)
        }
        val id = replies.single().getOrThrow()
        assertTrue(id.isNotEmpty())
        executor.runAll()
        val done = terminal(id)!!
        assertEquals(EngineEventKindMsg.JOB_DONE, done.kind)
        assertEquals(JobKindMsg.WAVEFORM, done.jobDone!!.kind)
        assertEquals(0, jobs.jobCount)
    }

    @Test
    fun startFailsTypedForExportsProxiesOfProxiesAndBeforeInitialize() {
        val jobs = registry()
        val export = mutableListOf<Result<String>>()
        jobs.start(request(JobKindMsg.EXPORT)) { export.add(it) }
        assertEquals(EngineErrorCode.internal, (export.single().exceptionOrNull() as EngineException).code)
        val proxyOfProxy = mutableListOf<Result<String>>()
        jobs.start(request(JobKindMsg.PROXY, isProxy = true)) { proxyOfProxy.add(it) }
        assertTrue(proxyOfProxy.single().isFailure)
        val bare = EngineContext(ContextWrapper(null), FakeThreads().threads)
        val early = mutableListOf<Result<String>>()
        JobRegistry(bare, concurrency = 1, workers = executor).start(request(JobKindMsg.WAVEFORM)) { early.add(it) }
        assertTrue(early.single().isFailure)
        assertEquals(0, executor.pending)
        assertFalse("no activity left behind", DiskCache.isActive)
    }

    @Test
    fun prioritiesThenStartOrderWithOneSlot() {
        val jobs = registry(concurrency = 1)
        jobs.enqueue(body("first"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("bg1"), JobPriorityMsg.BACKGROUND)
        jobs.enqueue(body("n1"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("bg2"), JobPriorityMsg.BACKGROUND)
        val late = jobs.enqueue(body("late"), JobPriorityMsg.BACKGROUND)
        assertEquals(1, jobs.runningCount)
        jobs.setPriority(late, JobPriorityMsg.NORMAL)
        executor.runAll()
        assertEquals(listOf("run first", "run n1", "run late", "run bg1", "run bg2"), log)
        assertEquals(0, jobs.jobCount)
    }

    @Test
    fun concurrencyIsOneOnMinimalAndLowAndTwoOtherwise() {
        assertEquals(1, JobRegistry.concurrencyFor(com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg.MINIMAL))
        assertEquals(1, JobRegistry.concurrencyFor(com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg.LOW))
        assertEquals(2, JobRegistry.concurrencyFor(com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg.MID))
        assertEquals(2, JobRegistry.concurrencyFor(com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg.HIGH))
        val jobs = registry(concurrency = 2)
        repeat(3) { jobs.enqueue(body("j$it"), JobPriorityMsg.NORMAL) }
        assertEquals(2, jobs.runningCount)
        assertEquals(2, executor.pending)
        executor.runNext()
        assertEquals("a finished job frees its slot", 2, jobs.runningCount)
        executor.runAll()
        assertEquals(0, jobs.jobCount)
    }

    @Test
    fun jobsWithTheSameKeyNeverRunTogether() {
        val jobs = registry(concurrency = 2)
        jobs.enqueue(body("p1", JobKindMsg.PROXY, key = "proxy-fp"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("p2", JobKindMsg.PROXY, key = "proxy-fp"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("w", key = "waveform-fp-0"), JobPriorityMsg.NORMAL)
        assertEquals(2, jobs.runningCount)
        executor.runAll()
        assertEquals(listOf("run p1", "run w", "run p2"), log)
    }

    @Test
    fun interactiveJobPreemptsTheLowestRunningJobWhichRestartsLater() {
        val jobs = registry(concurrency = 1)
        val bg = jobs.enqueue(body("bg"), JobPriorityMsg.BACKGROUND)
        val ui = jobs.enqueue(body("ui"), JobPriorityMsg.INTERACTIVE)
        // bg holds the slot; the interactive job asked it to stop.
        assertEquals(JobRegistry.State.RUNNING, jobs.state(bg))
        assertEquals(JobRegistry.State.QUEUED, jobs.state(ui))
        executor.runNext() // bg notices the pre-emption and stops
        assertEquals(JobRegistry.State.QUEUED, jobs.state(bg))
        assertEquals(1, jobs.restarts(bg))
        assertEquals(JobRegistry.State.RUNNING, jobs.state(ui))
        executor.runAll()
        assertEquals(listOf("run bg", "cleanUp bg", "run ui", "run bg"), log)
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(ui)!!.kind)
        assertEquals("pre-emption is not a cancel", EngineEventKindMsg.JOB_DONE, terminal(bg)!!.kind)
        assertEquals(1, deliver().count { it.jobId == bg && it.kind != EngineEventKindMsg.PROGRESS })
    }

    @Test
    fun interactiveJobDoesNotPreemptAnInteractiveOrANormalJobOfHigherRank() {
        val jobs = registry(concurrency = 1)
        val first = jobs.enqueue(body("ui1"), JobPriorityMsg.INTERACTIVE)
        jobs.enqueue(body("ui2"), JobPriorityMsg.INTERACTIVE)
        executor.runAll()
        assertEquals(listOf("run ui1", "run ui2"), log)
        assertEquals(0, jobs.restarts(first))
    }

    @Test
    fun heldJobsStoppedWaitsForThePausedJobsToReturnFromTheirBodies() {
        // QA-05 D9: an export starts its codecs only after the jobs it paused have stopped.
        val jobs = registry(concurrency = 3)
        val coordinator = FakeExportCoordinator(jobs)
        val proxy = jobs.enqueue(body("proxy", JobKindMsg.PROXY, key = "proxy-fp", proxy = "fp"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("wave"), JobPriorityMsg.BACKGROUND)
        val ui = jobs.enqueue(body("ui"), JobPriorityMsg.INTERACTIVE)
        assertEquals(3, jobs.runningCount)
        coordinator.startExport()
        var released = 0
        jobs.whenHeldJobsStopped { released++ }
        assertEquals("the paused jobs still run their bodies", 0, released)
        executor.runNext() // proxy stops (pre-empted)
        assertEquals(JobRegistry.State.QUEUED, jobs.state(proxy))
        assertEquals("the background job still runs", 0, released)
        executor.runNext() // wave stops
        assertEquals(1, released)
        // The interactive job is not paused by an export and never held the waiter.
        assertEquals(JobRegistry.State.RUNNING, jobs.state(ui))
        executor.runAll()
        assertEquals("the waiter runs once", 1, released)
        // Nothing paused running: at once.
        var now = 0
        jobs.whenHeldJobsStopped { now++ }
        assertEquals(1, now)
    }

    @Test
    fun heldJobsStoppedWaitersAreReleasedWhenTheExportEnds() {
        val jobs = registry(concurrency = 1)
        val coordinator = FakeExportCoordinator(jobs)
        jobs.enqueue(body("wave"), JobPriorityMsg.BACKGROUND)
        val export = coordinator.startExport()
        var released = 0
        jobs.whenHeldJobsStopped { released++ }
        assertEquals(0, released)
        // The export ends before the job noticed the pause: nothing is held any more.
        coordinator.finishExport(export)
        assertEquals(1, released)
        executor.runAll()
        assertEquals(1, released)
    }

    @Test
    fun exportPausesBackgroundAndProxyJobsAndResumesThemAfterwards() {
        val jobs = registry(concurrency = 2)
        val coordinator = FakeExportCoordinator(jobs)
        val proxy = jobs.enqueue(body("proxy", JobKindMsg.PROXY, key = "proxy-fp", proxy = "fp"), JobPriorityMsg.NORMAL)
        val wave = jobs.enqueue(body("wave"), JobPriorityMsg.BACKGROUND)
        assertEquals(ProxyStatusMsg.RUNNING, ProxyRegistry.status("fp", paths))
        val export = coordinator.startExport()
        assertTrue(jobs.isExportActive)
        executor.runAll() // both notice the pause and stop
        assertEquals(JobRegistry.State.QUEUED, jobs.state(proxy))
        assertEquals(JobRegistry.State.QUEUED, jobs.state(wave))
        assertEquals(ProxyStatusMsg.QUEUED, ProxyRegistry.status("fp", paths))
        // Nothing paused by the export starts while it runs, but normal non-proxy jobs still do.
        val normal = jobs.enqueue(body("normal"), JobPriorityMsg.NORMAL)
        val late = jobs.enqueue(body("lateBg"), JobPriorityMsg.BACKGROUND)
        assertEquals(1, jobs.runningCount)
        executor.runAll()
        assertNull(jobs.state(normal))
        assertEquals(JobRegistry.State.QUEUED, jobs.state(late))
        assertEquals(listOf("run proxy", "cleanUp proxy", "run wave", "cleanUp wave", "run normal"), log)
        coordinator.finishExport(export)
        assertEquals(2, jobs.runningCount)
        executor.runAll()
        executor.runAll()
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(proxy)!!.kind)
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(wave)!!.kind)
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(late)!!.kind)
        assertEquals("the proxy restarted once", 2, log.count { it == "run proxy" })
        assertEquals(ProxyStatusMsg.NO_PROXY, ProxyRegistry.status("fp", paths))
        assertFalse(DiskCache.isActive)
    }

    @Test
    fun proxyJobsArePausedByAnExportEvenAtInteractivePriority() {
        val jobs = registry(concurrency = 1)
        val coordinator = FakeExportCoordinator(jobs)
        val export = coordinator.startExport()
        val proxy = jobs.enqueue(body("proxy", JobKindMsg.PROXY, key = "proxy-fp2", proxy = "fp2"), JobPriorityMsg.INTERACTIVE)
        assertEquals(JobRegistry.State.QUEUED, jobs.state(proxy))
        assertEquals(0, executor.pending)
        assertEquals(ProxyStatusMsg.QUEUED, ProxyRegistry.status("fp2", paths))
        coordinator.finishExport(export)
        executor.runAll()
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(proxy)!!.kind)
    }

    @Test
    fun cancelOfAQueuedJobEndsItAtOnceAndCleansUp() {
        val jobs = registry(concurrency = 1)
        jobs.enqueue(body("running"), JobPriorityMsg.NORMAL)
        val queuedBody = body("queued")
        val queued = jobs.enqueue(queuedBody, JobPriorityMsg.NORMAL)
        jobs.cancel(queued)
        assertNull(jobs.state(queued))
        assertEquals(0, queuedBody.runs)
        assertEquals(1, queuedBody.cleanUps)
        val failure = terminal(queued)!!
        assertEquals(EngineEventKindMsg.FAILURE, failure.kind)
        assertEquals("cancelled", failure.failure!!.code)
        executor.runAll()
        assertEquals(listOf("run running", "cleanUp queued").sorted(), log.sorted())
        jobs.cancel("unknown-id") // ignored
    }

    @Test
    fun cancelOfARunningJobStopsItDeletesItsPartialOutputAndReportsCancelled() {
        val jobs = registry(concurrency = 1)
        lateinit var id: String
        val b = body("long")
        val part = File(paths.work, "long.part").apply { parentFile!!.mkdirs(); writeText("partial") }
        b.script = { control ->
            control.reportProgress(0.3)
            jobs.cancel(id) // arrives while the body runs
            assertTrue(control.isCancelled)
            assertTrue(control.isStopRequested)
        }
        val withCleanUp = object : MediaJobBody by b {
            override fun cleanUp() {
                b.cleanUp()
                part.delete()
            }
        }
        id = jobs.enqueue(withCleanUp, JobPriorityMsg.NORMAL)
        executor.runAll()
        assertFalse(".part removed", part.exists())
        val failure = terminal(id)!!
        assertEquals("cancelled", failure.failure!!.code)
        assertEquals(1, b.cleanUps)
        assertEquals(0, jobs.jobCount)
        assertFalse(DiskCache.isActive)
    }

    @Test
    fun cancelOverridesAPendingPreemption() {
        val control = RegistryJobControl("x")
        val seen = mutableListOf<JobStopReason>()
        control.onStop { seen.add(it) }
        assertTrue(control.stop(JobStopReason.PREEMPT))
        assertFalse(control.isCancelled)
        assertTrue(control.isStopRequested)
        assertEquals(EngineErrorCode.interrupted, runCatching { control.throwIfCancelled() }.exceptionOrNull().let { (it as EngineException).code })
        assertFalse("a second pre-emption changes nothing", control.stop(JobStopReason.PREEMPT))
        assertTrue(control.stop(JobStopReason.CANCEL))
        assertTrue(control.isCancelled)
        assertFalse("nothing overrides a cancel", control.stop(JobStopReason.PREEMPT))
        assertEquals(listOf(JobStopReason.PREEMPT, JobStopReason.CANCEL), seen)
        assertEquals(EngineErrorCode.cancelled, runCatching { control.throwIfCancelled() }.exceptionOrNull().let { (it as EngineException).code })
        val late = mutableListOf<JobStopReason>()
        control.onStop { late.add(it) }
        assertEquals("a late handler runs at once", listOf(JobStopReason.CANCEL), late)
    }

    @Test
    fun progressIsMonotonicAndEndsAtTheResult() {
        val jobs = registry(concurrency = 1)
        val b = body("p")
        b.script = { control ->
            control.reportProgress(0.5)
            control.reportProgress(0.3) // backwards: dropped
            control.reportProgress(Double.NaN) // dropped
            control.reportProgress(0.7)
            control.reportProgress(2.0) // clamped
        }
        val id = jobs.enqueue(b, JobPriorityMsg.NORMAL)
        executor.runAll()
        val mine = deliver().filter { it.jobId == id }
        val progress = mine.filter { it.kind == EngineEventKindMsg.PROGRESS }.map { it.progress!! }
        assertTrue("some progress delivered", progress.isNotEmpty())
        assertEquals(progress.sorted(), progress)
        assertEquals(1.0, progress.last(), 0.0)
        assertEquals(EngineEventKindMsg.JOB_DONE, mine.last().kind)
    }

    @Test
    fun failuresAreTypedCleanedUpAndMarkTheProxyFailed() {
        val jobs = registry(concurrency = 1)
        val b = body("broken", JobKindMsg.PROXY, key = "proxy-fp3", proxy = "fp3")
        b.script = { throw EngineException(EngineErrorCode.decodeFailed, "bad sample") }
        val id = jobs.enqueue(b, JobPriorityMsg.BACKGROUND)
        executor.runAll()
        val failure = terminal(id)!!
        assertEquals("decodeFailed", failure.failure!!.code)
        assertEquals(1, b.cleanUps)
        assertEquals(ProxyStatusMsg.FAILED, ProxyRegistry.status("fp3", paths))
        // A body that claims `cancelled` without a cancel is a bug, reported as internal.
        val liar = body("liar")
        liar.script = { throw EngineException(EngineErrorCode.cancelled, "cancelled") }
        val liarId = jobs.enqueue(liar, JobPriorityMsg.NORMAL)
        executor.runAll()
        assertEquals("internal", terminal(liarId)!!.failure!!.code)
        // A crash is internal and leaves the registry usable.
        val crash = body("crash")
        crash.script = { throw IllegalStateException("boom") }
        val crashId = jobs.enqueue(crash, JobPriorityMsg.NORMAL)
        executor.runAll()
        assertEquals("internal", terminal(crashId)!!.failure!!.code)
        assertEquals(0, jobs.jobCount)
        ProxyRegistry.mark("fp3", null)
    }

    @Test
    fun jobsKeepTheCacheActiveUntilTheyEnd() {
        val jobs = registry(concurrency = 1)
        assertFalse(DiskCache.isActive)
        val a = jobs.enqueue(body("a"), JobPriorityMsg.NORMAL)
        jobs.enqueue(body("b"), JobPriorityMsg.NORMAL)
        assertTrue("clear editor cache is refused while jobs exist", DiskCache.isActive)
        jobs.cancel(a)
        executor.runAll()
        assertFalse(DiskCache.isActive)
    }
}
