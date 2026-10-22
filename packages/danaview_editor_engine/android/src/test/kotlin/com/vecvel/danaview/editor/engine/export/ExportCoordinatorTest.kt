// OWNER: AND-11
//
// ExportCoordinator on the JVM with fake threads, a recording environment and pass doubles:
// - preflight never refuses for sequence counts (D-45) and reports the encoder warnings;
// - routing: above maxVisualSequences or the decoder instances the job goes to the MultiPassExport
//   hook (a test double standing in for AND-19); without a hook it still runs one pass;
// - progress, warnings (fallback, software encoder), completion, failure (partial output deleted),
//   cancel (partial output deleted), interrupt, detached completion (D-39), process death
//   (interrupted once), consume, the side effects (job registry / preview suspension / service via
//   the environment) and the AND-12 listener API;
// - the export mapping uses originals (never proxies); a plan referencing a render-preview file is
//   refused (D-45).

package com.vecvel.danaview.editor.engine.export

import android.content.ContextWrapper
import androidx.media3.transformer.ExportException
import com.vecvel.danaview.editor.engine.composition.FakeSourceTimeline
import com.vecvel.danaview.editor.engine.composition.ItemKind
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.glue.FakeThreads
import com.vecvel.danaview.editor.engine.media.WorkExemptions
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPreflightMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanRequirements
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ExportCoordinatorTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val fake = FakeThreads()
    private val ctx = EngineContext(ContextWrapper(null), fake.threads)
    private val events = mutableListOf<EngineEventMsg>()
    private val env = FakeEnvironment()
    private val single = PassDouble()
    private val multi = MultiPassDouble()
    private lateinit var paths: Paths
    private lateinit var coordinator: ExportCoordinator
    private var plan: RenderPlan = Plans.media()

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
            multiPass = multi
            timelineFactory = { FakeSourceTimeline() }
        }
    }

    @After
    fun tearDown() {
        fake.settle()
    }

    private val output: File get() = File(paths.work, "export-test.mp4")

    private fun <T> call(block: ((Result<T>) -> Unit) -> Unit): Result<T> {
        var r: Result<T>? = null
        block { r = it }
        fake.settle()
        return checkNotNull(r) { "no completion" }
    }

    private fun preflight(settings: com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg = Settings.msg()): Result<ExportPreflightMsg> =
        call { coordinator.preflight(ByteArray(1), settings, it) }

    private fun start(
        settings: com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg = Settings.msg(),
        whenDetached: DetachedHandoffMsg = DetachedHandoffMsg.SAVE_TO_GALLERY,
        out: File = output,
    ): Result<String> = call { coordinator.start(ByteArray(1), settings, out.absolutePath, "My title", whenDetached, it) }

    private fun activeJobs(): List<ExportJobRecordMsg> = call<List<ExportJobRecordMsg>> { coordinator.activeJobs(it) }.getOrThrow()

    private fun progressEvents(jobId: String): List<ExportProgressMsg> =
        events.filter { it.kind == EngineEventKindMsg.EXPORT_PROGRESS && it.jobId == jobId }.mapNotNull { it.exportProgress }

    private fun terminal(jobId: String): EngineEventMsg =
        events.single { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }

    // ---- preflight ----

    @Test
    fun preflightNeverRefusesForSequenceCounts() {
        plan = Plans.media(slots = 6)
        env.budget = DecoderBudget(maxVisualSequences = 2, maxDecoderInstances = 6)
        val p = preflight().getOrThrow()
        assertTrue(p.ok)
        assertEquals(listOf(ExportWarnings.LAYERS_VS_RESOLUTION), p.warnings.map { it.code })
        assertEquals(2160L, p.maxHeightForPlan)
    }

    @Test
    fun preflightFlagsASoftwareEncoder() {
        coordinator.selector = HardwareEncoderSelector(Codecs.softwareOnly)
        val p = preflight().getOrThrow()
        assertTrue(p.ok)
        assertEquals(listOf(ExportWarnings.SOFTWARE_ENCODER), p.warnings.map { it.code })
        assertEquals(1080L, p.maxHeightForPlan)
    }

    @Test
    fun preflightReportsHevcFallbackAndPortraitRetry() {
        coordinator.selector = HardwareEncoderSelector(
            Codecs.catalog(Codecs.encoder("c2.qti.avc.encoder", Codecs.AVC, true, maxW = 1920, maxH = 1920, landscapeOnly = true)),
        )
        plan = Plans.media(w = 1080, h = 1920)
        val p = preflight(Settings.msg(w = 1080, h = 1920, codec = VideoCodecMsg.HEVC)).getOrThrow()
        assertTrue(p.ok)
        assertEquals(listOf(ExportWarnings.HEVC_UNAVAILABLE, ExportWarnings.PORTRAIT_RETRIED), p.warnings.map { it.code })
    }

    @Test
    fun preflightIsNotOkWhenNoEncoderTakesTheSize() {
        coordinator.selector = HardwareEncoderSelector(Codecs.catalog(Codecs.encoder("hw", Codecs.AVC, true, maxW = 1920, maxH = 1088)))
        plan = Plans.media(w = 3840, h = 2160)
        val p = preflight(Settings.msg(w = 3840, h = 2160)).getOrThrow()
        assertFalse(p.ok)
        assertEquals(1080L, p.maxHeightForPlan)
    }

    @Test
    fun preflightOfMovIsNotOk() {
        val p = preflight(Settings.msg(container = ExportContainerMsg.MOV)).getOrThrow()
        assertFalse(p.ok)
        assertEquals(listOf(ExportCoordinator.CONTAINER_UNAVAILABLE), p.warnings.map { it.code })
    }

    @Test
    fun planChecks() {
        plan = Plans.media(target = PlanTarget.PREVIEW)
        assertEquals(EngineErrorCode.planInvalid, (preflight().exceptionOrNull() as EngineException).code)
        plan = Plans.media(req = PlanRequirements(offline = listOf("it_l0#v")))
        val offline = preflight().exceptionOrNull() as EngineException
        assertEquals(EngineErrorCode.mediaOffline, offline.code)
        assertEquals("it_l0#v", offline.itemId)
        plan = Plans.media(req = PlanRequirements(pendingReverse = listOf("it_l0#v")))
        assertEquals(EngineErrorCode.planInvalid, (start().exceptionOrNull() as EngineException).code)
        plan = Plans.media(fps = 24, gridFps = 30)
        assertEquals(EngineErrorCode.internal, (start(Settings.msg(fps = 30)).exceptionOrNull() as EngineException).code)
        // gridFps 30 with output fps 24 is a valid export.
        assertTrue(start(Settings.msg(fps = 24)).isSuccess)
        assertEquals(0, events.count { it.kind == EngineEventKindMsg.FAILURE })
    }

    @Test
    fun aPlanReferencingARenderPreviewFileIsRefused() {
        // D-45: render-preview files (<cache>/danaview/editor/renders/) are never exported, as an
        // asset or as its proxy; the AND-19 work directory and other cache files are fine.
        val renders = File(paths.cacheRoot, "renders")
        fun withSrc(uri: String, proxy: String? = null) = Plans.media().let { p ->
            p.copy(assets = p.assets.mapValues { (_, a) -> a.copy(uri = uri, proxyUri = proxy) })
        }
        plan = withSrc("file://" + File(renders, "abc.mp4").absolutePath)
        val asAsset = preflight().exceptionOrNull() as EngineException
        assertEquals(EngineErrorCode.planInvalid, asAsset.code)
        assertEquals("md_src", asAsset.itemId)
        assertEquals(EngineErrorCode.planInvalid, (start().exceptionOrNull() as EngineException).code)
        plan = withSrc("file:///fixtures/src.mp4", proxy = "file://" + File(renders, "abc.mp4").absolutePath)
        assertEquals(EngineErrorCode.planInvalid, (start().exceptionOrNull() as EngineException).code)
        plan = withSrc("file://" + File(paths.work, "export-x/pass1.mp4").absolutePath)
        assertTrue(preflight().isSuccess)
        assertEquals("no pass started for a refused plan", 0, single.starts + multi.starts)
    }

    // ---- routing ----

    @Test
    fun aboveMaxVisualSequencesGoesToTheMultiPassHook() {
        plan = Plans.media(slots = 5)
        env.budget = DecoderBudget(maxVisualSequences = 3, maxDecoderInstances = 32)
        val id = start().getOrThrow()
        assertEquals(1, multi.starts)
        assertEquals(0, single.starts)
        val job = multi.job!!
        assertEquals(id, job.jobId)
        assertEquals(MultiPassRouting.Load(slots = 5, peakDecoders = 5), job.load)
        assertEquals(File(paths.work, "export-$id"), job.workDir)
        assertEquals(output.absoluteFile, job.output.absoluteFile)
        assertEquals(ExportWarnings.LAYERS_VS_RESOLUTION, progressEvents(id).first().warnings.single().code)
        multi.progress(0.5)
        multi.complete("c2.qti.avc.encoder")
        fake.settle()
        assertEquals(EngineEventKindMsg.JOB_DONE, terminal(id).kind)
    }

    @Test
    fun peakDecodersAboveInstancesMinusTwoGoToTheMultiPassHook() {
        plan = Plans.media(slots = 3)
        env.budget = DecoderBudget(maxVisualSequences = 6, maxDecoderInstances = 4)
        start().getOrThrow()
        assertEquals(1, multi.starts)
        assertEquals(0, single.starts)
    }

    @Test
    fun withinBudgetRunsOnePass() {
        plan = Plans.media(slots = 3)
        env.budget = DecoderBudget(maxVisualSequences = 3, maxDecoderInstances = 16)
        start().getOrThrow()
        assertEquals(0, multi.starts)
        assertEquals(1, single.starts)
    }

    @Test
    fun withoutAHookAMultiPassPlanStillRunsOnePass() {
        coordinator.multiPass = null
        coordinator.discoverMultiPass = false
        assertNull(coordinator.multiPassExport())
        plan = Plans.media(slots = 5)
        env.budget = DecoderBudget(maxVisualSequences = 2, maxDecoderInstances = 0)
        val id = start().getOrThrow()
        assertEquals(1, single.starts)
        assertEquals(listOf(ExportWarnings.LAYERS_VS_RESOLUTION), progressEvents(id).first().warnings.map { it.code })
    }

    @Test
    fun routingRule() {
        val budget = DecoderBudget(maxVisualSequences = 3, maxDecoderInstances = 6)
        assertEquals(4, budget.maxDecoders)
        assertEquals(Int.MAX_VALUE, DecoderBudget(3, 0).maxDecoders)
        assertFalse(MultiPassRouting.needsMultiPass(MultiPassRouting.Load(3, 3), budget))
        assertTrue(MultiPassRouting.needsMultiPass(MultiPassRouting.Load(4, 2), budget))
        assertTrue(MultiPassRouting.needsMultiPass(MultiPassRouting.Load(3, 5), DecoderBudget(6, 6)))
        // Sequential layers in one slot need one decoder; two slots overlapping in the middle need two.
        val p = Plans.media(slots = 2, seconds = 3)
        val a = p.layers[0]
        val b = p.layers[1]
        val shifted = p.copy(layers = listOf(a.copy(t1 = 1_000_000), b.copy(t0 = 2_000_000)))
        assertEquals(MultiPassRouting.Load(2, 1), MultiPassRouting.load(shifted))
        assertEquals(MultiPassRouting.Load(2, 2), MultiPassRouting.load(p))
    }

    // ---- life cycle ----

    @Test
    fun progressAndCompletion() {
        plan = Plans.media(seconds = 2, fps = 30)
        val id = start().getOrThrow()
        assertTrue(id.startsWith("ex_"))
        assertEquals(listOf("started:$id"), env.calls)
        assertEquals(listOf(ExportJobStateKindMsg.RUNNING), activeJobs().map { it.state })
        val first = progressEvents(id).first()
        assertEquals(ExportPhaseMsg.PREPARING, first.phase)
        assertEquals(60L, first.framesTotal)
        fake.main.advance(300)
        single.progress(0.5)
        fake.settle()
        val half = progressEvents(id).last()
        assertEquals(ExportPhaseMsg.RENDERING, half.phase)
        assertEquals(0.5, half.fraction, 0.0)
        assertEquals(30L, half.framesDone)
        single.complete("c2.qti.avc.encoder", bytes = 2048)
        fake.settle()
        val last = progressEvents(id).last()
        assertEquals(ExportPhaseMsg.FINISHING, last.phase)
        assertEquals(1.0, last.fraction, 0.0)
        val done = terminal(id)
        assertEquals(EngineEventKindMsg.JOB_DONE, done.kind)
        assertEquals(JobKindMsg.EXPORT, done.jobDone!!.kind)
        val r = done.jobDone!!.exportResult!!
        assertEquals(output.absolutePath, r.path)
        assertEquals(2048L, r.bytes)
        assertEquals(plan.durUs, r.durationUs)
        assertEquals("c2.qti.avc.encoder", r.videoEncoderName)
        assertTrue(r.hardwareEncoder)
        assertTrue(output.isFile)
        assertEquals(emptyList<Any>(), activeJobs())
        assertEquals(listOf("started:$id", "ended:$id"), env.calls)
    }

    @Test
    fun aSoftwareEncoderThatRanIsFlagged() {
        val id = start().getOrThrow()
        single.complete("c2.android.avc.encoder")
        fake.settle()
        assertFalse(terminal(id).jobDone!!.exportResult!!.hardwareEncoder)
        assertTrue(progressEvents(id).last().warnings.any { it.code == ExportWarnings.SOFTWARE_ENCODER })
    }

    @Test
    fun fallbackAndRetryWarningsReachProgress() {
        val id = start().getOrThrow()
        single.warn(ExportWarnings.fallbackApplied())
        fake.settle()
        assertEquals(listOf(ExportWarnings.FALLBACK_APPLIED), progressEvents(id).last().warnings.map { it.code })
        single.warn(ExportWarnings.fallbackApplied())
        single.warn(ExportWarnings.portraitRetried())
        fake.settle()
        assertEquals(listOf(ExportWarnings.FALLBACK_APPLIED, ExportWarnings.PORTRAIT_RETRIED), progressEvents(id).last().warnings.map { it.code })
    }

    @Test
    fun failureDeletesThePartialOutput() {
        val id = start().getOrThrow()
        output.writeBytes(ByteArray(100))
        File(paths.work, "export-$id").mkdirs()
        single.listener!!.onFailed(
            ExportException.createForCodec(IllegalStateException("x"), ExportException.ERROR_CODE_ENCODER_INIT_FAILED, ExportException.CodecInfo("f", true, false, "enc")),
        )
        fake.settle()
        val failure = terminal(id)
        assertEquals(EngineEventKindMsg.FAILURE, failure.kind)
        assertEquals(EngineErrorCode.encoderUnavailable.name, failure.failure!!.code)
        assertFalse(output.exists())
        assertFalse(File(paths.work, "export-$id").exists())
        assertEquals(emptyList<Any>(), activeJobs())
        assertEquals(listOf("started:$id", "ended:$id"), env.calls)
    }

    /** QA-05 D8's chain: the image asset loader could not open a generated image the system purged. */
    private fun purgedImage(): ExportException {
        val png = File(paths.engineAssets, "dv_opaque_ff000000_1280x720.png")
        val fnf = java.io.FileNotFoundException("${png.path}: open failed: ENOENT (No such file or directory)")
        val source = androidx.media3.datasource.FileDataSource.FileDataSourceException(fnf, androidx.media3.common.PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND)
        return ExportException.createForAssetLoader(source, ExportException.ERROR_CODE_IO_UNSPECIFIED)
    }

    @Test
    fun aPurgedEngineFileUnderLowStorageIsDiskFull() {
        env.storageLow = true
        val id = start().getOrThrow()
        single.listener!!.onFailed(ExportErrors.map(purgedImage()))
        fake.settle()
        val f = terminal(id).failure!!
        assertEquals(EngineErrorCode.diskFull.name, f.code)
        assertTrue(f.retryable)
        assertFalse(f.message.contains(paths.cacheRoot.name))
        assertFalse(output.exists())
    }

    @Test
    fun aPurgedEngineFileWithSpaceLeftIsIo() {
        env.storageLow = false
        val id = start().getOrThrow()
        single.listener!!.onFailed(purgedImage())
        fake.settle()
        assertEquals(EngineErrorCode.io.name, terminal(id).failure!!.code)
    }

    @Test
    fun aMissingUserFileKeepsItsMapping() {
        env.storageLow = true
        val id = start().getOrThrow()
        val user = java.io.FileNotFoundException("${File(paths.media, "a.mp4").path}: open failed: ENOENT (No such file or directory)")
        single.listener!!.onFailed(ExportException.createForAssetLoader(user, ExportException.ERROR_CODE_IO_FILE_NOT_FOUND))
        fake.settle()
        assertEquals(EngineErrorCode.mediaOffline.name, terminal(id).failure!!.code)
    }

    @Test
    fun anOutputPurgedBeforeCompletionIsAStorageFailure() {
        env.storageLow = true
        val id = start().getOrThrow()
        // The muxer finished writing an unlinked file: nothing is left at the output path.
        single.listener!!.onCompleted("c2.qti.avc.encoder")
        fake.settle()
        assertEquals(EngineErrorCode.diskFull.name, terminal(id).failure!!.code)
    }

    @Test
    fun anEmptyOutputIsStillAnEncodingFailure() {
        env.storageLow = true
        val id = start().getOrThrow()
        single.complete("c2.qti.avc.encoder", bytes = 0)
        fake.settle()
        assertEquals(EngineErrorCode.encodingFailed.name, terminal(id).failure!!.code)
    }

    @Test
    fun passThatThrowsFailsTheJob() {
        coordinator.singlePass = ExportPass { _, _ -> throw EngineException(EngineErrorCode.mediaOffline, "source unreadable", itemId = "it_l0#v") }
        val id = start().getOrThrow()
        val f = terminal(id).failure!!
        assertEquals(EngineErrorCode.mediaOffline.name, f.code)
        assertEquals("it_l0#v", f.itemId)
    }

    @Test
    fun cancelStopsAndDeletesThePartialOutput() {
        val id = start().getOrThrow()
        output.writeBytes(ByteArray(100))
        assertTrue(call<Unit> { coordinator.cancel(id, it) }.isSuccess)
        assertEquals(1, single.cancelled)
        assertFalse(output.exists())
        assertEquals(EngineErrorCode.cancelled.name, terminal(id).failure!!.code)
        assertEquals(emptyList<Any>(), activeJobs())
        // Idempotent; late callbacks of the stopped pass are ignored.
        assertTrue(call<Unit> { coordinator.cancel(id, it) }.isSuccess)
        single.complete("c2.qti.avc.encoder")
        fake.settle()
        assertEquals(1, events.count { it.jobId == id && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) })
        assertTrue(call<Unit> { coordinator.cancel("ex_unknown", it) }.isSuccess)
    }

    @Test
    fun interruptLeavesAOneShotRecord() {
        val id = start().getOrThrow()
        coordinator.interrupt(id)
        fake.settle()
        assertEquals(EngineErrorCode.interrupted.name, terminal(id).failure!!.code)
        assertTrue(terminal(id).failure!!.retryable)
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), activeJobs().map { it.state })
        coordinator.consumeJobRecord(id)
        assertEquals(emptyList<Any>(), activeJobs())
    }

    @Test
    fun completionWithoutADartListenerKeepsAOneShotRecord() {
        env.listener = false
        val id = start(whenDetached = DetachedHandoffMsg.KEEP_FOR_LATER).getOrThrow()
        single.complete("c2.qti.avc.encoder")
        fake.settle()
        val record = activeJobs().single()
        assertEquals(ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED, record.state)
        assertEquals(output.absolutePath, record.result!!.path)
        assertFalse(record.savedToGallery)
        assertTrue(output.isFile)
        assertTrue("exempt from the work/ wipe", WorkExemptions.live(paths).contains(output.name))
        // Offered until consumed.
        assertEquals(1, activeJobs().size)
        coordinator.consumeJobRecord(id)
        assertEquals(emptyList<Any>(), activeJobs())
        assertFalse(WorkExemptions.live(paths).contains(output.name))
    }

    @Test
    fun aDetachedHandlerReplacesTheDefault() {
        env.listener = false
        coordinator.detachedHandler = DetachedCompletionHandler { it.savedToGallery("content://media/external/video/media/7", keptFile = false) }
        start().getOrThrow()
        single.complete("c2.qti.avc.encoder")
        fake.settle()
        val record = activeJobs().single()
        assertTrue(record.savedToGallery)
        assertEquals("content://media/external/video/media/7", record.savedUri)
        assertNull(record.result)
    }

    @Test
    fun aJobOfADeadProcessIsReportedInterruptedOnce() {
        ActiveExportStore(File(paths.cacheRoot, ActiveExportStore.FILE_NAME), "previous-process")
            .begin("ex_dead", File(paths.work, "export-ex_dead.mp4"), Settings.msg(), DetachedHandoffMsg.SAVE_TO_GALLERY)
        assertEquals(listOf("ex_dead" to ExportJobStateKindMsg.INTERRUPTED), activeJobs().map { it.jobId to it.state })
        assertEquals(1, activeJobs().size)
        coordinator.consumeJobRecord("ex_dead")
        assertEquals(emptyList<Any>(), activeJobs())
    }

    @Test
    fun startFailures() {
        val outside = File(temp.root, "elsewhere.mp4")
        assertEquals(EngineErrorCode.permissionDenied, (start(out = outside).exceptionOrNull() as EngineException).code)
        coordinator.selector = HardwareEncoderSelector(Codecs.catalog())
        assertEquals(EngineErrorCode.encoderUnavailable, (start().exceptionOrNull() as EngineException).code)
        assertEquals(EngineErrorCode.notSupportedOnDevice, (start(Settings.msg(container = ExportContainerMsg.MOV)).exceptionOrNull() as EngineException).code)
        assertEquals(emptyList<Any>(), env.calls)
        assertEquals(emptyList<Any>(), activeJobs())
    }

    @Test
    fun hevcFallsBackToH264ForTheRun() {
        coordinator.selector = HardwareEncoderSelector(Codecs.catalog(Codecs.encoder("c2.qti.avc.encoder", Codecs.AVC, true)))
        val id = start(Settings.msg(codec = VideoCodecMsg.HEVC)).getOrThrow()
        assertEquals(ExportVideoCodec.H264, single.job!!.settings.codec)
        assertEquals(ExportVideoCodec.H264, single.job!!.passConfig.settings.codec)
        assertEquals(listOf(ExportWarnings.HEVC_UNAVAILABLE), progressEvents(id).first().warnings.map { it.code })
    }

    @Test
    fun listenersForTheExportService() {
        val log = mutableListOf<String>()
        coordinator.addJobListener(object : ExportJobListener {
            override fun onJobStarted(job: ExportJobInfo) {
                log += "started:${job.title}:${job.whenDetached}"
            }

            override fun onJobProgress(jobId: String, progress: ExportProgressMsg) {
                log += "progress:${progress.phase}"
            }

            override fun onJobEnded(jobId: String, outcome: ExportOutcome) {
                log += "ended:$outcome"
            }
        })
        val id = start().getOrThrow()
        assertEquals("My title", coordinator.job(id)!!.title)
        assertEquals(listOf(id), coordinator.runningJobs().map { it.jobId })
        single.complete("c2.qti.avc.encoder")
        fake.settle()
        assertNull(coordinator.job(id))
        assertEquals(
            listOf("started:My title:SAVE_TO_GALLERY", "progress:PREPARING", "progress:FINISHING", "ended:COMPLETED"),
            log,
        )
    }

    @Test
    fun theExportMappingUsesOriginals() {
        plan = Plans.media().let { p ->
            p.copy(assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, "file:///original.mp4", fp = "src", proxyUri = "file:///proxy.mp4", w = 1280, h = 720, durUs = 60_000_000)))
        }
        start().getOrThrow()
        val spec = single.job!!.map()
        val media = spec.sequences.flatMap { it.items }.filter { it.kind == ItemKind.MEDIA }
        assertEquals(listOf("file:///original.mp4"), media.map { it.uri })
        assertEquals(30, spec.outputFps)
        assertNotNull(spec.sequences.first { it.index == 0 })
    }
}
