// OWNER: AND-19
//
// PrecomposeExport driven through AND-11's production ExportCoordinator on the JVM (fake threads,
// a recording environment, a recording PassRunner standing in for Transformer):
// - the coordinator discovers it by reflection (MULTI_PASS_CLASS) and routes a 6-slot plan with
//   maxVisualSequences 2 to it instead of refusing;
// - passes run bottom-up, one at a time: intermediates `work/export-<jobId>/pre-<n>.mp4` with
//   all-intra 4× settings, each deleted once the next pass has consumed it, the final pass with the
//   export settings writes the output; the work dir is pinned against the work/ wipe meanwhile;
// - one progress fraction over all passes, never decreasing, finishing at 1.0;
// - cancel in each pass and a failure in any pass leave no intermediate and no output;
// - the disk preflight refuses with diskFull before anything is written;
// - only the final pass's fallback / portrait retry become progress warnings.

package com.vecvel.danaview.editor.engine.precompose

import android.content.ContextWrapper
import com.vecvel.danaview.editor.engine.composition.FakeSourceTimeline
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.export.Codecs
import com.vecvel.danaview.editor.engine.export.DecoderBudget
import com.vecvel.danaview.editor.engine.export.ExportCoordinator
import com.vecvel.danaview.editor.engine.export.ExportJob
import com.vecvel.danaview.editor.engine.export.ExportJobListener
import com.vecvel.danaview.editor.engine.export.ExportPassListener
import com.vecvel.danaview.editor.engine.export.MultiPassRouting
import com.vecvel.danaview.editor.engine.export.ExportWarnings
import com.vecvel.danaview.editor.engine.export.FakeEnvironment
import com.vecvel.danaview.editor.engine.export.HardwareEncoderSelector
import com.vecvel.danaview.editor.engine.export.PassDouble
import com.vecvel.danaview.editor.engine.export.Settings
import com.vecvel.danaview.editor.engine.export.precompose.DiskEstimate
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposeExport
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposeObserver
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposePlan
import com.vecvel.danaview.editor.engine.glue.FakeThreads
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportWarningMsg
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PrecomposeExportTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val fake = FakeThreads()
    private val ctx = EngineContext(ContextWrapper(null), fake.threads)
    private val events = mutableListOf<EngineEventMsg>()
    private val env = FakeEnvironment(budget = DecoderBudget(maxVisualSequences = 2, maxDecoderInstances = 0))
    private val runner = RecordingRunner()
    private val single = PassDouble()
    private val planned = mutableListOf<Pair<PrecomposePlan, DiskEstimate>>()
    private val passLog = mutableListOf<String>()
    private val listened = mutableListOf<Pair<String, ExportProgressMsg>>()
    private lateinit var paths: Paths
    private lateinit var coordinator: ExportCoordinator
    private lateinit var precompose: PrecomposeExport
    private var plan: RenderPlan = PrecomposePlans.overlapping(6, audio = true)

    @Before
    fun setUp() {
        val root = temp.newFolder("app")
        paths = Paths.fromDart(File(root, "cache/danaview/editor").absolutePath, File(root, "files/danaview/editor").absolutePath)
        ctx.installRoots(paths)
        fake.main.onMain { ctx.events.attach { events.add(it) } }
        coordinator = ExportCoordinator(ctx).apply {
            environment = env
            planDecoder = { plan }
            selector = HardwareEncoderSelector(Codecs.phone)
            singlePass = single
            timelineFactory = { FakeSourceTimeline() }
        }
        coordinator.addJobListener(object : ExportJobListener {
            override fun onJobProgress(jobId: String, progress: ExportProgressMsg) {
                listened += jobId to progress
            }
        })
        precompose = coordinator.multiPassExport() as PrecomposeExport
        precompose.runner = runner
        precompose.freeBytes = { Long.MAX_VALUE }
        precompose.observer = object : PrecomposeObserver {
            override fun onPlanned(jobId: String, plan: PrecomposePlan, disk: DiskEstimate) {
                planned += plan to disk
            }

            override fun onPassStarted(jobId: String, number: Int, total: Int) {
                passLog += "start $number/$total"
            }

            override fun onPassCompleted(jobId: String, number: Int, total: Int) {
                passLog += "done $number/$total"
            }
        }
    }

    @After
    fun tearDown() {
        fake.settle()
    }

    private val output: File get() = File(paths.work, "export-test.mp4")

    private fun start(): String {
        var r: Result<String>? = null
        coordinator.start(ByteArray(1), Settings.msg(), output.absolutePath, "My title", DetachedHandoffMsg.SAVE_TO_GALLERY) { r = it }
        fake.settle()
        return checkNotNull(r).getOrThrow()
    }

    private fun workDir(jobId: String) = File(paths.work, "export-$jobId")

    private fun progress(jobId: String): List<ExportProgressMsg> =
        events.filter { it.kind == EngineEventKindMsg.EXPORT_PROGRESS && it.jobId == jobId }.mapNotNull { it.exportProgress }

    private fun terminal(jobId: String): EngineEventMsg =
        events.single { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }

    private fun settle(block: () -> Unit) {
        block()
        fake.settle()
    }

    private fun isPinned(dir: File) = DiskCache.activeWorkPaths.contains(dir.absoluteFile.invariantSeparatorsPath)

    @Test
    fun theCoordinatorDiscoversThePrecomposeByReflection() {
        val fresh = ExportCoordinator(ctx)
        assertTrue(fresh.multiPassExport() is PrecomposeExport)
        assertEquals(ExportCoordinator.MULTI_PASS_CLASS, PrecomposeExport::class.java.name)
        // @Keep (CLASS retention, read by R8) is checked by the release build's consumer rules, not here.
        assertNotNull(PrecomposeExport::class.java.getConstructor(EngineContext::class.java))
    }

    @Test
    fun aSixSlotPlanAboveTwoVisualSequencesExportsInFivePasses() {
        val id = start()
        assertEquals("routed to the precompose, not the single pass", 0, single.starts)
        val dir = workDir(id)
        val (split, disk) = planned.single()
        assertEquals(5, split.totalPasses)
        assertTrue(disk.extraBytes > 0)
        assertTrue("work dir pinned against the work/ wipe", isPinned(dir))
        val exportSettings = runner.started.first().job.settings

        for (n in 1..4) {
            val s = runner.started.last()
            assertEquals(n, s.request.number)
            assertEquals(File(dir, "pre-$n.mp4"), s.request.output)
            assertEquals("all-intra", 0, s.request.settings.keyframeIntervalMs)
            assertEquals("4x bitrate", exportSettings.videoBitrate * 4, s.request.settings.videoBitrate)
            assertEquals(exportSettings.width, s.request.settings.width)
            assertEquals(exportSettings.height, s.request.settings.height)
            assertEquals(exportSettings.fps, s.request.settings.fps)
            assertEquals(TrackTypes.VIDEO, s.request.spec.sequences.first().trackTypes)
            assertTrue(s.request.spec.audioSequences.isEmpty())
            // The previous intermediate is this pass's input and still exists.
            if (n > 1) assertTrue(File(dir, "pre-${n - 1}.mp4").isFile)
            settle { runner.progress(0.5) }
            settle { runner.complete(bytes = 1000 + n) }
            // Consumed inputs are deleted at once: pass n+1 reads pre-n and writes pre-(n+1); the
            // final pass reads pre-4 and writes the output (outside the work dir).
            val alive = if (n < 4) listOf("pre-$n.mp4", "pre-${n + 1}.mp4") else listOf("pre-4.mp4")
            assertEquals(alive, dir.list()!!.sorted())
        }

        val last = runner.started.last()
        assertEquals(5, runner.started.size)
        assertEquals(output, last.request.output)
        assertEquals(exportSettings, last.request.settings)
        assertEquals(TrackTypes.VIDEO_AND_AUDIO, last.request.spec.sequences.first().trackTypes)
        assertEquals(1, last.request.spec.audioSequences.size)
        assertEquals(SequenceKind.BACKGROUND, last.request.spec.sequences.first { it.kind != SequenceKind.LAYERS && it.kind != SequenceKind.CLOCK_BAND }.kind)
        assertTrue("the final pass reads pre-4", last.request.snapshotPlan.layers.any { it.id == "precompose:pre-4" })
        settle { runner.progress(0.5) }
        settle { runner.complete("c2.qti.avc.encoder", bytes = 5000) }

        val end = terminal(id)
        assertEquals(EngineEventKindMsg.JOB_DONE, end.kind)
        assertEquals(output.absolutePath, end.jobDone!!.exportResult!!.path)
        assertEquals(5000L, end.jobDone!!.exportResult!!.bytes)
        assertEquals("c2.qti.avc.encoder", end.jobDone!!.exportResult!!.videoEncoderName)
        assertFalse("no intermediate left", dir.exists())
        assertFalse("pin released", isPinned(dir))
        assertEquals((1..5).flatMap { listOf("start $it/5", "done $it/5") }, passLog)

        // One fraction over all passes, never decreasing, ending at 1.0 (every sample, as AND-12's
        // listener sees them; the Dart event stream rate-limits the same values to 4 Hz).
        val samples = listened.filter { it.first == id }.map { it.second }
        val fractions = samples.map { it.fraction }
        assertTrue(fractions.zipWithNext().all { (a, b) -> b >= a })
        assertEquals(1.0, fractions.last(), 0.0)
        assertEquals(ExportPhaseMsg.FINISHING, samples.last().phase)
        assertEquals(1.0, progress(id).last().fraction, 0.0)
        val rendering = samples.filter { it.phase == ExportPhaseMsg.RENDERING }.map { it.fraction }
        assertTrue("several distinct fractions across the passes: $rendering", rendering.toSet().size >= 9)
        assertTrue(rendering.all { it < 1.0 })
        assertTrue(progress(id).last().warnings.any { it.code == ExportWarnings.LAYERS_VS_RESOLUTION })
    }

    @Test
    fun cancelDuringEachPassLeavesNoIntermediate() {
        for (cancelIn in 1..5) {
            runner.started.clear()
            val id = start()
            val dir = workDir(id)
            for (n in 1 until cancelIn) settle { runner.complete() }
            assertEquals(cancelIn, runner.current.request.number)
            assertTrue(runner.current.request.output.exists())
            settle { coordinator.cancel(id) {} }
            assertEquals("pass $cancelIn stopped", 1, runner.current.cancelled)
            val end = terminal(id)
            assertEquals(EngineEventKindMsg.FAILURE, end.kind)
            assertEquals(EngineErrorCode.cancelled.name, end.failure!!.code)
            assertFalse("pass $cancelIn: intermediates deleted", dir.exists())
            assertFalse("pass $cancelIn: output deleted", output.exists())
            assertFalse(isPinned(dir))
            // Nothing runs after the cancel.
            val before = runner.started.size
            fake.settle()
            assertEquals(before, runner.started.size)
        }
    }

    @Test
    fun aFailureInAnyPassDeletesTheIntermediatesAndFailsWithTheMappedCode() {
        for (failIn in 1..5) {
            runner.started.clear()
            val id = start()
            val dir = workDir(id)
            for (n in 1 until failIn) settle { runner.complete() }
            settle { runner.current.listener.onFailed(EngineException(EngineErrorCode.decoderInitFailed, "no decoder")) }
            val end = terminal(id)
            assertEquals(EngineEventKindMsg.FAILURE, end.kind)
            assertEquals(EngineErrorCode.decoderInitFailed.name, end.failure!!.code)
            assertFalse("pass $failIn: intermediates deleted", dir.exists())
            assertFalse(output.exists())
            assertFalse(isPinned(dir))
        }
    }

    @Test
    fun theDiskPreflightCountsTheIntermediates() {
        var asked: File? = null
        precompose.freeBytes = { asked = it; 1_000_000L }
        val id = start()
        val (_, disk) = planned.single()
        assertTrue("1 MB is less than ${disk.peakBytes}", disk.peakBytes > 1_000_000L)
        val end = terminal(id)
        assertEquals(EngineErrorCode.diskFull.name, end.failure!!.code)
        assertEquals(workDir(id), asked)
        assertTrue("nothing was rendered", runner.started.isEmpty())
        assertFalse(workDir(id).exists())
        // Exactly enough space is enough.
        planned.clear()
        precompose.freeBytes = { Long.MAX_VALUE }
        val ok = start()
        val need = planned.single().second.peakBytes
        assertEquals(1, runner.started.size)
        settle { coordinator.cancel(ok) {} }
        runner.started.clear()
        precompose.freeBytes = { need }
        start()
        assertEquals(1, runner.started.size)
    }

    @Test
    fun onlyTheFinalPassRaisesFallbackAndPortraitWarnings() {
        val id = start()
        settle { runner.current.listener.onFallbackApplied() }
        settle { runner.current.listener.onPortraitRetried() }
        repeat(4) { settle { runner.complete() } }
        assertTrue(listened.none { (_, p) -> p.warnings.any { it.code == ExportWarnings.FALLBACK_APPLIED || it.code == ExportWarnings.PORTRAIT_RETRIED } })
        settle { runner.current.listener.onFallbackApplied() }
        settle { runner.current.listener.onPortraitRetried() }
        settle { runner.complete() }
        val codes = progress(id).last().warnings.map { it.code }
        assertTrue(codes.toString(), codes.contains(ExportWarnings.FALLBACK_APPLIED))
        assertTrue(codes.toString(), codes.contains(ExportWarnings.PORTRAIT_RETRIED))
    }

    @Test
    fun aPlanUnderTheBudgetRunsOnePassOfThePlanItself() {
        // The coordinator routes only plans above the budget; given one that fits, the precompose
        // degrades to one ordinary pass (no intermediate, no work dir).
        val id = start()
        val routed = runner.current.job
        settle { coordinator.cancel(id) {} }
        runner.started.clear()
        val fits = PrecomposePlans.overlapping(2, audio = true)
        val job = ExportJob(
            jobId = "ex_fits", plan = fits, settings = routed.settings, choice = routed.choice, output = File(paths.work, "export-fits.mp4"),
            workDir = File(paths.work, "export-ex_fits"), budget = DecoderBudget(2, 0), load = MultiPassRouting.load(fits), hdrMode = 0,
            context = routed.context, looper = routed.looper, passConfig = routed.passConfig,
            timelines = { FakeSourceTimeline() }, compositions = { _, _ -> error("not built on the JVM") }, assetLoaders = { null },
        )
        val outcome = mutableListOf<String>()
        precompose.start(job, object : ExportPassListener {
            override fun onProgress(fraction: Double) {}
            override fun onWarning(warning: ExportWarningMsg) {}
            override fun onCompleted(videoEncoderName: String?) { outcome += "done $videoEncoderName" }
            override fun onFailed(error: Throwable) { outcome += "failed" }
        })
        assertEquals(1, runner.started.size)
        val req = runner.current.request
        assertTrue(req.isFinal)
        assertEquals(job.output, req.output)
        assertEquals(job.settings, req.settings)
        assertSame(fits, req.snapshotPlan)
        assertEquals(2, req.spec.slotSequences.size)
        assertFalse(job.workDir.exists())
        runner.complete("enc")
        assertEquals(listOf("done enc"), outcome)
    }
}
