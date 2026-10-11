// OWNER: ENG-08
//
// The six host API glues (ARCH §12.6) against fake ports: argument validation, the thread each call
// runs on (queue hops), error codes, and the Android-specific answers (resume, bookmarks,
// excludeFromBackup).

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.BackgroundExportKindMsg
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.vwish.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.vwish.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.vwish.editor.engine.pigeon.EditingModeKindMsg
import com.vecvel.vwish.editor.engine.pigeon.EditingModeMsg
import com.vecvel.vwish.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineConfigMsg
import com.vecvel.vwish.editor.engine.pigeon.EnginePigeonError
import com.vecvel.vwish.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.vwish.editor.engine.pigeon.JobKindMsg
import com.vecvel.vwish.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.LookSpecMsg
import com.vecvel.vwish.editor.engine.pigeon.LoopMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaPickKindMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaPickSourceMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaRefMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.vwish.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.VideoCodecMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HostApisTest {
    private val fake = FakeThreads()
    private val calls = PortCalls(fake.trace)
    private var paths: Paths? = TestRoots.paths
    private val pathsFn = { paths }

    private val engine = EngineHostApiImpl(fake.threads, FakeRootPort(calls))
    private val preview = PreviewHostApiImpl(fake.threads, FakePreviewPort(calls))
    private val jobs = JobsHostApiImpl(fake.threads, FakeJobsPort(calls), pathsFn)
    private val export = ExportHostApiImpl(fake.threads, FakeExportPort(calls), pathsFn)
    private val recorder = RecorderHostApiImpl(fake.threads, FakeRecorderPort(calls), pathsFn)
    private val platform = PlatformHostApiImpl(fake.threads, FakePlatformPort(calls), pathsFn)

    private val media = ResolvedMediaMsg(uri = "content://media/external/video/1", fingerprint = "fp1", isProxy = false)
    private val work = "${TestRoots.CACHE}/work/out.mp4"
    private val settings = EncodeSettingsMsg(
        container = ExportContainerMsg.MP4, codec = VideoCodecMsg.H264, width = 1920, height = 1080, fps = 30,
        videoBitrate = 8_000_000, audioBitrate = 192_000, audioSampleRate = 48_000, audioChannels = 2,
        keyframeIntervalMs = 1000, stripLocation = true,
    )

    /** Calls [block] on main, settles every thread, and returns the reply. */
    private fun <T> call(block: (callback: (Result<T>) -> Unit) -> Unit): Reply<T> {
        val reply = Reply<T>(fake.trace)
        fake.main.onMain { block(reply.callback) }
        fake.settle()
        return reply
    }

    /** Asserts that exactly one port call [name] happened, on [where]. */
    private fun assertRan(name: String, where: Where) {
        val matching = calls.log.filter { it.name == name }
        assertEquals("calls of $name: ${calls.names()}", 1, matching.size)
        assertEquals("$name thread", where, matching.single().where)
    }

    private fun assertNoPortCall() = assertTrue("unexpected port calls ${calls.names()}", calls.log.isEmpty())

    private fun capabilitiesMsg() = CapabilitiesMsg(
        supported = true, tier = DeviceTierMsg.MID, lowMemoryDevice = false, h264Encode = true, hevcEncode = true,
        hardwareH264 = true, hardwareHevc = true, movContainer = false, maxExportWidth = 2560, maxExportHeight = 1440,
        maxFpsByHeight = mapOf(1080L to 60L), maxConcurrentVideoLayers = 4, maxVisualSequences = 4, maxTextureSize = 8192,
        maxPreviewLongSide = 1280, backgroundKind = BackgroundExportKindMsg.FOREGROUND_SERVICE, backgroundGpu = false,
        voiceRecording = true, proxiesRecommended = false, holdFrame = true, fpsUpconversion = true, externalDrop = true,
        minSpeed = 0.1, maxSpeed = 10.0, maxAudioSpeed = 4.0, maxLutSize = 65, planVersions = listOf(1L),
    )

    // ---- EngineHostApi ----

    @Test
    fun initializeValidatesRootsOnMainAndInstallsThemOnIo() {
        val ok = call<Unit> { engine.initialize(EngineConfigMsg(TestRoots.CACHE, TestRoots.SUPPORT), it) }
        ok.value()
        assertRan("installRoots", Where.IO)
        assertEquals(TestRoots.paths, calls.log.single().args.single())

        calls.log.clear()
        call<Unit> { engine.initialize(EngineConfigMsg("relative", TestRoots.SUPPORT), it) }.assertError("internal")
        assertNoPortCall()
    }

    @Test
    fun capabilitiesRoundTripOnIo() {
        val caps = capabilitiesMsg()
        calls.answer = { _, _ -> Result.success(caps) }
        val reply = call<CapabilitiesMsg> { engine.capabilities(it) }
        assertEquals(caps, reply.value())
        assertRan("capabilities", Where.IO)
    }

    @Test
    fun engineRootChecks() {
        call<Any?> { engine.compatibility("", it) }.assertError("internal")
        call<Any?> { engine.compatibility("relative/a.mp4", it) }.assertError("internal")
        call<Any?> { engine.probe(media.copy(fingerprint = ""), it) }.assertError("internal")
        call<Long> { engine.freeBytes("relative", it) }.assertError("internal")
        assertNoPortCall()
        call<Any?> { engine.compatibility("/storage/emulated/0/Movies/a.mkv", it) }
        call<Any?> { engine.probe(media, it) }
        calls.answer = { _, _ -> Result.success(123L) }
        assertEquals(123L, call<Long> { engine.freeBytes(TestRoots.CACHE, it) }.value())
        assertRan("compatibility", Where.IO)
        assertRan("probe", Where.IO)
        assertRan("freeBytes", Where.IO)
    }

    @Test
    fun serviceFailuresKeepTheirCode() {
        calls.answer = { _, _ -> Result.failure(EngineException(EngineErrorCode.unsupportedMedia, "codec in /data/a.mkv")) }
        val error = call<Any?> { engine.probe(media, it) }.assertError("unsupportedMedia")
        assertTrue(!error.message!!.contains("/data"))
    }

    @Test
    fun trimCachesIsSynchronousAndNeverThrows() {
        fake.main.onMain { engine.trimCaches(CacheTrimLevelMsg.CLEAR_ALL) }
        assertRan("trimCaches", Where.MAIN)
        val throwing = EngineHostApiImpl(fake.threads, object : EngineRootPort by FakeRootPort(calls) {
            override fun trimCaches(level: CacheTrimLevelMsg) = throw IllegalStateException("x")
        })
        fake.main.onMain { throwing.trimCaches(CacheTrimLevelMsg.BACKGROUND) }
    }

    // ---- PreviewHostApi ----

    @Test
    fun everyPreviewCallRunsOnThePreviewLane() {
        val sid = "session-1"
        val plan = "{}".toByteArray()
        call<Any?> { preview.open(PreviewConfigMsg(1920, 1080, 30, PreviewQualityMsg.AUTO, false), it) }
        call<Any?> { preview.setPlan(sid, plan, it) }
        call<Any?> { preview.applyPatch(sid, plan, it) }
        call<Long> { preview.play(sid, LoopMsg(0, 1_000_000), it) }
        call<Long> { preview.pause(sid, it) }
        call<Any?> { preview.seek(sid, 5_333_334, true, it) }
        call<Unit> { preview.setQuality(sid, PreviewQualityMsg.HALF, it) }
        call<Unit> { preview.setUseProxies(sid, true, it) }
        call<Unit> { preview.setEditingMode(sid, EditingModeMsg(EditingModeKindMsg.MATTE, "item"), it) }
        call<Unit> { preview.showSourceFrame(sid, media, 0, it) }
        call<Any?> { preview.sampleColor(sid, "item", 0.5, 1.0, it) }
        call<List<ByteArray>> { preview.renderLookStills(sid, "item", listOf(LookSpecMsg("l", "file:///x.vlut", 33, 1.0)), 120, it) }
        call<Unit> { preview.refresh(sid, it) }
        call<ByteArray> { preview.debugCaptureFrame(sid, it) }
        call<Unit> { preview.dispose(sid, it) }
        fake.main.onMain {
            preview.setTransient(sid, "item", "{}".toByteArray())
            preview.clearTransient(sid, "item")
        }
        fake.settle()
        val names = listOf(
            "open", "setPlan", "applyPatch", "play", "pause", "seek", "setQuality", "setUseProxies", "setEditingMode",
            "showSourceFrame", "sampleColor", "renderLookStills", "refresh", "debugCaptureFrame", "dispose",
            "setTransient", "clearTransient",
        )
        assertEquals(names, calls.names())
        assertTrue(calls.log.all { it.where == Where.PREVIEW })
    }

    @Test
    fun previewArgumentChecks() {
        val sid = "s"
        call<Any?> { preview.open(PreviewConfigMsg(1920, 1080, 29, PreviewQualityMsg.AUTO, false), it) }.assertError("internal")
        call<Any?> { preview.open(PreviewConfigMsg(0, 1080, 30, PreviewQualityMsg.AUTO, false), it) }.assertError("internal")
        call<Any?> { preview.setPlan(sid, ByteArray(0), it) }.assertError("planInvalid")
        call<Any?> { preview.applyPatch("", "{}".toByteArray(), it) }.assertError("internal")
        call<Long> { preview.play(sid, LoopMsg(10, 10), it) }.assertError("internal")
        call<Any?> { preview.seek(sid, -1, true, it) }.assertError("internal")
        call<Any?> { preview.sampleColor(sid, "i", 1.5, 0.0, it) }.assertError("internal")
        call<Any?> { preview.sampleColor(sid, "i", Double.NaN, 0.0, it) }.assertError("internal")
        call<Unit> { preview.setEditingMode(sid, EditingModeMsg(EditingModeKindMsg.CROP_SOURCE, null), it) }.assertError("internal")
        call<List<ByteArray>> { preview.renderLookStills(sid, "i", emptyList(), 120, it) }.assertError("internal")
        call<List<ByteArray>> {
            preview.renderLookStills(sid, "i", listOf(LookSpecMsg("l", "file:///x.vlut", 99, 1.0)), 120, it)
        }.assertError("internal")
        call<Unit> { preview.showSourceFrame(sid, media, -5, it) }.assertError("internal")
        assertNoPortCall()
        try {
            fake.main.onMain { preview.setTransient(sid, "item", ByteArray(0)) }
            fail("expected EnginePigeonError")
        } catch (e: EnginePigeonError) {
            assertEquals("internal", e.code)
        }
    }

    // ---- JobsHostApi ----

    @Test
    fun jobsRunOnTheJobsLaneAndProxyStatusOnIo() {
        val thumb = ThumbnailRequestMsg(media, intervalMs = 1000, tileIndex = 0, heightPx = 64, framesPerTile = 8, proxy = false)
        call<Any?> { jobs.thumbnailTile("t1", thumb, ThumbPriorityMsg.VISIBLE, it) }
        calls.answer = { _, _ -> Result.success("job-1") }
        val id = call<String> { jobs.startJob(JobRequestMsg(JobKindMsg.WAVEFORM, media, JobPriorityMsg.NORMAL), it) }
        assertEquals("job-1", id.value())
        call<Any?> { jobs.proxyStatus("fp1", it) }
        fake.main.onMain {
            jobs.cancelThumbnail("t1")
            jobs.cancelJob("job-1")
            jobs.setJobPriority("job-1", JobPriorityMsg.INTERACTIVE)
        }
        fake.settle()
        assertRan("thumbnailTile", Where.JOBS)
        assertRan("startJob", Where.JOBS)
        assertRan("proxyStatus", Where.IO)
        assertRan("cancelThumbnail", Where.JOBS)
        assertRan("cancelJob", Where.JOBS)
        assertRan("setJobPriority", Where.JOBS)
    }

    @Test
    fun jobRequestsAreCheckedPerKind() {
        fun job(kind: JobKindMsg, start: Long? = null, end: Long? = null, t: Long? = null, out: String? = null) =
            JobRequestMsg(kind, media, JobPriorityMsg.NORMAL, sourceStartUs = start, sourceEndUs = end, sourceTimeUs = t, outputPath = out)
        val derived = "${TestRoots.SUPPORT}/derived/r.mp4"
        call<String> { jobs.startJob(job(JobKindMsg.REVERSE, out = derived), it) }.assertError("internal")
        call<String> { jobs.startJob(job(JobKindMsg.REVERSE, 2_000_000, 1_000_000, out = derived), it) }.assertError("internal")
        call<String> { jobs.startJob(job(JobKindMsg.REVERSE, 0, 1_000_000, out = "/sdcard/r.mp4"), it) }.assertError("permissionDenied")
        call<String> { jobs.startJob(job(JobKindMsg.FREEZE, t = -1, out = derived), it) }.assertError("internal")
        call<String> { jobs.startJob(job(JobKindMsg.SPEECH_AUDIO, 0, 10, out = null), it) }.assertError("internal")
        call<String> { jobs.startJob(job(JobKindMsg.EXPORT), it) }.assertError("internal")
        val thumb = ThumbnailRequestMsg(media, intervalMs = 0, tileIndex = 0, heightPx = 64, framesPerTile = 8, proxy = false)
        call<Any?> { jobs.thumbnailTile("t1", thumb, ThumbPriorityMsg.VISIBLE, it) }.assertError("internal")
        assertNoPortCall()

        call<String> { jobs.startJob(job(JobKindMsg.REVERSE, 0, 1_000_000, out = derived), it) }
        call<String> { jobs.startJob(job(JobKindMsg.FREEZE, t = 5_000_000, out = "${TestRoots.SUPPORT}/projects/p/assets/stills/a.png"), it) }
        call<String> { jobs.startJob(job(JobKindMsg.SPEECH_AUDIO, 0, 10_000_000, out = "${TestRoots.SPEECH}/work/a.wav"), it) }
        assertEquals(3, calls.log.size)
    }

    @Test
    fun outputPathsNeedInitializedRoots() {
        paths = null
        val request = JobRequestMsg(JobKindMsg.FREEZE, media, JobPriorityMsg.NORMAL, sourceTimeUs = 0, outputPath = work)
        call<String> { jobs.startJob(request, it) }.assertError("internal")
        assertNoPortCall()
    }

    // ---- ExportHostApi ----

    @Test
    fun exportRunsOnTheExportLane() {
        val plan = "{}".toByteArray()
        calls.answer = { name, _ -> if (name == "start") Result.success("export-1") else Result.success(emptyList<Any>()) }
        call<Any?> { export.preflight(plan, settings, it) }
        assertEquals("export-1", call<String> { export.start(plan, settings, work, "My video", DetachedHandoffMsg.SAVE_TO_GALLERY, it) }.value())
        call<Unit> { export.cancel("export-1", it) }
        call<Any?> { export.activeJobs(it) }
        fake.main.onMain { export.consumeJobRecord("export-1") }
        fake.settle()
        assertEquals(listOf("preflight", "start", "cancel", "activeJobs", "consumeJobRecord"), calls.names())
        assertTrue(calls.log.all { it.where == Where.EXPORT })
    }

    @Test
    fun exportChecksAndResume() {
        val plan = "{}".toByteArray()
        call<String> { export.start(plan, settings, "/sdcard/Movies/x.mp4", "t", DetachedHandoffMsg.SAVE_TO_GALLERY, it) }
            .assertError("permissionDenied")
        call<String> { export.start(ByteArray(0), settings, work, "t", DetachedHandoffMsg.SAVE_TO_GALLERY, it) }.assertError("planInvalid")
        call<Any?> { export.preflight(plan, settings.copy(fps = 23), it) }.assertError("internal")
        call<Any?> { export.preflight(plan, settings.copy(width = 0), it) }.assertError("internal")
        call<String> { export.resume("export-1", it) }.assertError("notSupportedOnDevice")
        assertNoPortCall()
    }

    // ---- RecorderHostApi ----

    @Test
    fun recorderThreadsAndChecks() {
        call<Any?> { recorder.permission(it) }
        call<Any?> { recorder.requestPermission(it) }
        call<Unit> { recorder.openSettings(it) }
        call<String> { recorder.start("${TestRoots.SUPPORT}/projects/p/assets/recordings/r.wav", it) }
        call<Any?> { recorder.stop("rec-1", it) }
        call<Unit> { recorder.cancel("rec-1", it) }
        assertRan("permission", Where.IO)
        assertRan("requestPermission", Where.MAIN)
        assertRan("openSettings", Where.MAIN)
        assertRan("start", Where.IO)
        assertRan("stop", Where.IO)
        assertRan("cancel", Where.IO)
        calls.log.clear()
        call<String> { recorder.start("/sdcard/r.wav", it) }.assertError("permissionDenied")
        call<Any?> { recorder.stop("", it) }.assertError("internal")
        assertNoPortCall()
    }

    // ---- PlatformHostApi ----

    @Test
    fun platformThreads() {
        val ref = MediaRefMsg(uri = "content://com.android.providers/document/1")
        call<Any?> { platform.pick(MediaPickRequestMsg(MediaPickSourceMsg.PHOTOS, listOf(MediaPickKindMsg.VIDEO), true), it) }
        call<Any?> { platform.saveToPhotos(work, it) }
        call<Any?> { platform.saveToFiles(work, "My video.mp4", it) }
        call<Any?> { platform.share(work, it) }
        call<Unit> { platform.persistUriGrant(ref.uri, it) }
        call<Unit> { platform.releaseUriGrant(ref.uri, it) }
        call<Any?> { platform.remainingGrantBudget(it) }
        call<Any?> { platform.stat(ref, it) }
        call<Any?> { platform.quickHash(ref, it) }
        call<Any?> { platform.requestNotificationPermission(it) }
        call<Any?> { platform.acquireBackground("Captions", it) }
        call<Unit> { platform.updateBackground("lease", 0.5, it) }
        call<Unit> { platform.releaseBackground("lease", it) }
        call<Unit> { platform.setDropTargetEnabled(true, it) }
        val onMain = listOf("pick", "saveToFiles", "share", "requestNotificationPermission", "acquireBackground", "updateBackground",
            "releaseBackground", "setDropTargetEnabled")
        val onIo = listOf("saveToPhotos", "persistUriGrant", "releaseUriGrant", "remainingGrantBudget", "stat", "quickHash")
        onMain.forEach { assertRan(it, Where.MAIN) }
        onIo.forEach { assertRan(it, Where.IO) }
    }

    @Test
    fun platformChecksAndAndroidAnswers() {
        call<ByteArray> { platform.createBookmark("file:///a.mp4", it) }.assertError("notSupportedOnDevice")
        call<Any?> { platform.resolveBookmark(byteArrayOf(1), it) }.assertError("notSupportedOnDevice")
        call<Unit> { platform.persistUriGrant("file:///a.mp4", it) }.assertError("internal")
        call<Any?> { platform.pick(MediaPickRequestMsg(MediaPickSourceMsg.FILES, emptyList(), false), it) }.assertError("internal")
        call<Any?> { platform.share("/sdcard/x.mp4", it) }.assertError("permissionDenied")
        call<Any?> { platform.saveToFiles(work, "../x.mp4", it) }.assertError("internal")
        call<Unit> { platform.updateBackground("lease", 2.0, it) }.assertError("internal")
        call<Any?> { platform.stat(MediaRefMsg(uri = ""), it) }.assertError("internal")
        assertNoPortCall()
    }

    @Test
    fun excludeFromBackupAcceptsOnlyEditorAndSpeechTrees() {
        call<Unit> { platform.excludeFromBackup("${TestRoots.SUPPORT}/media", it) }.value()
        call<Unit> { platform.excludeFromBackup(TestRoots.SPEECH, it) }.value()
        call<Unit> { platform.excludeFromBackup("/data/user/0/app/files/other", it) }.assertError("permissionDenied")
        call<Unit> { platform.excludeFromBackup("relative", it) }.assertError("internal")
        assertNoPortCall()
    }
}
