// OWNER: AND-05
//
// Proxy jobs end to end on the emulator through the real JobRegistry, ProxyJob (Media3
// Transformer) and ProxyRegistry, with the ENG-05 fixtures (BUILD_PLAN AND-05):
//
// - vfr_720p.mp4: every proxy presentation time equals the source's (VFR kept), 960x540 H.264;
// - frame_counter_1080p30.mp4: 960x540, same 240 PTS, sync frames at most 0.33 s apart (GOP);
// - tone_under_video.mp4: the audio is AAC; rotated_90.mov: the proxy displays portrait;
// - cancel: the job ends `cancelled`, no `.part` stays in work/, no proxy, status noProxy;
// - paused during export (a fake coordinator drives `setExportActive`): the running proxy stops,
//   its `.part` is deleted, it does not run while the export runs, and completes afterwards;
// - hlg_10bit_720p.mov: an SDR proxy where the device can tone-map; otherwise a typed failure with
//   nothing left behind (the x86_64 emulator has no HEVC Main10 decoder: HDR -> SDR itself is
//   deferred to a device, AND-01 V-N5).
// The PTS tests use software decoders first (ProxyTestSupport: the emulator's goldfish H.264 decoder
// drops a B-frame), so the criterion "proxy PTS equal on the VFR fixture" is met ONLY with software
// decoders on the API 35 emulator. defaultDecodersKeepTimestamps runs the production decoder choice:
// it checks that no delivered frame changes its timestamp and bounds the loss measured on API 35
// (frame 1); it is not evidence of frame-exactness. On the API 29 emulator the production path
// loses frames 1-5 (both OMX decoders), so that bound fails there: see ProxyJob.kt "KNOWN
// LIMITATION" (deferred to a real API 29 device and a mid-tier device, QA-04). Timings are
// emulator numbers.

package com.vecvel.vwish.editor.engine.proxy

import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineEventSink
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.JobRegistry
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.TestFixtures
import com.vecvel.vwish.editor.engine.media.ProxyRegistry
import com.vecvel.vwish.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg
import com.vecvel.vwish.editor.engine.pigeon.JobKindMsg
import com.vecvel.vwish.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.ProxyStatusMsg
import com.vecvel.vwish.editor.engine.pigeon.ResolvedMediaMsg
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** What a test needs to know about one video track. */
data class VideoTrack(
    val mime: String,
    val width: Int,
    val height: Int,
    val rotation: Int,
    /** Presentation times in µs, ascending. */
    val ptsUs: LongArray,
    /** Presentation times of sync samples, ascending. */
    val syncUs: LongArray,
    val colorTransfer: Int?,
    val profile: Int?,
    val audioMime: String?,
) {
    /** Display size after the rotation. */
    val displayWidth: Int get() = if (rotation % 180 != 0) height else width
    val displayHeight: Int get() = if (rotation % 180 != 0) width else height

    companion object {
        fun read(file: File): VideoTrack {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.absolutePath)
                var video = -1
                var audioMime: String? = null
                for (i in 0 until extractor.trackCount) {
                    val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME).orEmpty()
                    if (mime.startsWith("video/") && video < 0) video = i
                    if (mime.startsWith("audio/") && audioMime == null) audioMime = mime
                }
                check(video >= 0) { "no video track" }
                val format = extractor.getTrackFormat(video)
                extractor.selectTrack(video)
                val pts = ArrayList<Long>()
                val sync = ArrayList<Long>()
                while (true) {
                    val t = extractor.sampleTime
                    if (t < 0) break
                    pts.add(t)
                    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) sync.add(t)
                    extractor.advance()
                }
                fun int(key: String) = if (format.containsKey(key)) format.getInteger(key) else null
                return VideoTrack(
                    mime = format.getString(MediaFormat.KEY_MIME).orEmpty(),
                    width = format.getInteger(MediaFormat.KEY_WIDTH),
                    height = format.getInteger(MediaFormat.KEY_HEIGHT),
                    rotation = int(MediaFormat.KEY_ROTATION) ?: 0,
                    ptsUs = pts.sorted().toLongArray(),
                    syncUs = sync.sorted().toLongArray(),
                    colorTransfer = int(MediaFormat.KEY_COLOR_TRANSFER),
                    profile = int(MediaFormat.KEY_PROFILE),
                    audioMime = audioMime,
                )
            } finally {
                extractor.release()
            }
        }
    }
}

/** Stands in for AND-11's ExportCoordinator: tells the registry when an export runs. */
class FakeExportCoordinator(private val jobs: JobRegistry) {
    fun startExport(id: String) = jobs.setExportActive(id, true)
    fun finishExport(id: String) = jobs.setExportActive(id, false)
}

@RunWith(AndroidJUnit4::class)
class ProxyJobTest {
    companion object {
        private const val TAG = "VwishProxyTest"
        private lateinit var ctx: EngineContext
        private lateinit var paths: Paths
        private val events: MutableList<EngineEventMsg> = Collections.synchronizedList(ArrayList())
        private val sink = EngineEventSink { events.add(it) }

        @BeforeClass
        @JvmStatic
        fun setUp() {
            val app = TestFixtures.targetContext.applicationContext
            ctx = EngineContext(app, EngineThreads.android())
            val cache = File(app.cacheDir, "proxy-test/vwish/editor")
            val support = File(app.filesDir, "proxy-test/vwish/editor")
            cache.deleteRecursively()
            support.parentFile?.deleteRecursively()
            paths = Paths.fromDart(cache.absolutePath, support.absolutePath)
            ctx.installRoots(paths)
            ctx.proxyJob.assetLoaderFactory = ProxyTestDecoders::softwareFirst
            InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.attach(sink) }
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.detach(sink) }
            ctx.threads.shutdown()
        }
    }

    private fun source(name: String): File = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    private fun request(name: String, fingerprint: String, priority: JobPriorityMsg = JobPriorityMsg.NORMAL) = JobRequestMsg(
        kind = JobKindMsg.PROXY,
        media = ResolvedMediaMsg(uri = source(name).absolutePath, fingerprint = fingerprint, isProxy = false),
        priority = priority,
    )

    private fun start(jobs: JobRegistry, request: JobRequestMsg): String {
        ProxyRegistry.proxyFile(request.media.fingerprint, paths).delete()
        val latch = CountDownLatch(1)
        var id: Result<String>? = null
        jobs.start(request) {
            id = it
            latch.countDown()
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        return id!!.getOrThrow()
    }

    private fun terminal(jobId: String): EngineEventMsg? = synchronized(events) {
        events.lastOrNull { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }
    }

    private fun awaitTerminal(jobId: String, timeoutMs: Long = 180_000): EngineEventMsg {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            terminal(jobId)?.let { return it }
            Thread.sleep(20)
        }
        fail("job did not end within $timeoutMs ms")
        error("unreachable")
    }

    private fun await(what: String, timeoutMs: Long = 60_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("timed out waiting for $what")
            Thread.sleep(5)
        }
    }

    private fun partFiles(): List<File> = paths.work.listFiles().orEmpty().filter { it.name.endsWith(".part") }

    /** The durationUs of the last proxy() asset. */
    private var lastDurationUs: Long? = null

    /** Runs a proxy to completion and returns the proxy file. */
    private fun proxy(name: String, fingerprint: String): File {
        val jobs = JobRegistry(ctx, concurrency = 1)
        val started = System.nanoTime()
        val id = start(jobs, request(name, fingerprint))
        val end = awaitTerminal(id)
        assertEquals("job ${end.failure?.code} ${end.failure?.message}", EngineEventKindMsg.JOB_DONE, end.kind)
        val asset = end.jobDone!!.asset!!
        lastDurationUs = asset.durationUs
        val file = File(asset.path)
        assertEquals(ProxyRegistry.proxyFile(fingerprint, paths).absoluteFile, file.absoluteFile)
        assertTrue(file.isFile)
        assertEquals(file.length(), asset.sizeBytes)
        assertEquals(ProxyStatusMsg.READY, ProxyRegistry.status(fingerprint, paths))
        assertTrue("no partial output left", partFiles().isEmpty())
        val progress = synchronized(events) { events.filter { it.jobId == id && it.kind == EngineEventKindMsg.PROGRESS }.map { it.progress!! } }
        assertEquals("progress never moves backwards", progress.sorted(), progress)
        Log.i(TAG, "$name proxy: ${file.length() / 1024} KB in ${(System.nanoTime() - started) / 1_000_000} ms (emulator), duration ${asset.durationUs} µs")
        return file
    }

    /** Source frame indices whose time has no proxy frame within 100 µs. */
    private fun missing(source: VideoTrack, proxy: VideoTrack): List<Int> =
        source.ptsUs.indices.filter { i -> proxy.ptsUs.none { abs(it - source.ptsUs[i]) <= 100 } }

    private fun assertSamePts(source: VideoTrack, proxy: VideoTrack, label: String) {
        assertEquals("$label frame count (missing source frames ${missing(source, proxy)})", source.ptsUs.size, proxy.ptsUs.size)
        var maxDelta = 0L
        for (i in source.ptsUs.indices) maxDelta = maxOf(maxDelta, abs(source.ptsUs[i] - proxy.ptsUs[i]))
        Log.i(TAG, "$label: ${source.ptsUs.size} frames, max |proxy pts - source pts| = $maxDelta µs")
        // The proxy's MP4 timescale rounds each time by at most a few µs; one 1/600 s tick is 1667 µs.
        assertTrue("$label pts differ by up to $maxDelta µs", maxDelta <= 100)
    }

    @Test
    fun vfrProxyKeepsEverySourcePresentationTime() {
        val src = VideoTrack.read(source("vfr_720p.mp4"))
        val proxy = VideoTrack.read(proxy("vfr_720p.mp4", "fp-vfr"))
        assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, proxy.mime)
        assertEquals(960, proxy.displayWidth)
        assertEquals(540, proxy.displayHeight)
        assertEquals(143, src.ptsUs.size)
        assertSamePts(src, proxy, "vfr_720p")
        // VFR is preserved: the 0.5 s hold of frame 60 is still there.
        val gaps = (1 until proxy.ptsUs.size).map { proxy.ptsUs[it] - proxy.ptsUs[it - 1] }
        assertTrue(gaps.max() >= 490_000)
        assertTrue(gaps.min() <= 20_000)
    }

    @Test
    fun constantRateProxyIs540pH264WithAShortGop() {
        val file = proxy("frame_counter_1080p30.mp4", "fp-1080")
        val src = VideoTrack.read(source("frame_counter_1080p30.mp4"))
        val proxy = VideoTrack.read(file)
        assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, proxy.mime)
        assertEquals(960, proxy.width)
        assertEquals(540, proxy.height)
        assertSamePts(src, proxy, "frame_counter_1080p30")
        val syncGaps = (1 until proxy.syncUs.size).map { proxy.syncUs[it] - proxy.syncUs[it - 1] }
        val kbps = file.length() * 8 / 1000 / 8
        Log.i(TAG, "1080p30 proxy: ${proxy.syncUs.size} sync frames, max sync gap ${syncGaps.maxOrNull()} µs, ~$kbps kb/s (emulator encoder)")
        assertTrue("sync frames every 0.33 s (GOP about 10 frames): ${proxy.syncUs.size}", proxy.syncUs.size >= 20)
        assertTrue("max sync gap ${syncGaps.max()} µs", syncGaps.max() <= 400_000)
        assertEquals(null, proxy.audioMime)
        assertEquals("asset duration (240 frames at 30 fps)", 8_000_000.0, lastDurationUs!!.toDouble(), 34_000.0)
    }

    @Test
    fun defaultDecodersKeepTimestamps() {
        // Production decoder choice (Media3 default). On the API 35 emulator it loses source frame 1
        // of vfr_720p.mp4 (ProxyJob.kt KNOWN LIMITATION, an open investigation); whatever it
        // delivers keeps the source timestamps. The loss bound below is the API 35 measurement, a
        // regression guard, not the AND-05 criterion (that one is met with software decoders only).
        val hook = ctx.proxyJob.assetLoaderFactory
        ctx.proxyJob.assetLoaderFactory = null
        try {
            val src = VideoTrack.read(source("vfr_720p.mp4"))
            val proxy = VideoTrack.read(proxy("vfr_720p.mp4", "fp-vfr-default"))
            val lost = missing(src, proxy)
            Log.i(TAG, "default decoders: ${proxy.ptsUs.size}/${src.ptsUs.size} frames, lost source frames $lost (emulator decoder)")
            assertTrue("at most one frame lost by the emulator decoder: $lost", lost.size <= 1)
            for (t in proxy.ptsUs) {
                assertTrue("proxy time $t µs is a source time", src.ptsUs.any { abs(it - t) <= 100 })
            }
        } finally {
            ctx.proxyJob.assetLoaderFactory = hook
        }
    }

    @Test
    fun audioIsAacAndRotatedSourcesDisplayUpright() {
        val av = VideoTrack.read(proxy("tone_under_video.mp4", "fp-av"))
        assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, av.audioMime)
        assertEquals(540, minOf(av.displayWidth, av.displayHeight))
        val rotated = VideoTrack.read(proxy("rotated_90.mov", "fp-rot"))
        Log.i(TAG, "rotated_90 proxy: coded ${rotated.width}x${rotated.height}, rotation ${rotated.rotation}")
        assertEquals("displayed portrait like the source", 540, rotated.displayWidth)
        assertEquals(960, rotated.displayHeight)
    }

    @Test
    fun matroskaAndWebmSourcesGetMp4Proxies() {
        for ((name, fp) in listOf("sample_h264_aac.mkv" to "fp-mkv", "sample_vp9_opus.webm" to "fp-webm")) {
            val proxy = VideoTrack.read(proxy(name, fp))
            val src = VideoTrack.read(source(name))
            assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, proxy.mime)
            assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, proxy.audioMime)
            assertEquals(src.ptsUs.size, proxy.ptsUs.size)
        }
    }

    @Test
    fun cancelEndsCancelledAndCleansUp() {
        val jobs = JobRegistry(ctx, concurrency = 1)
        val id = start(jobs, request("frame_counter_1080p30.mp4", "fp-cancel"))
        await(".part to appear", 30_000) { partFiles().isNotEmpty() }
        jobs.cancel(id)
        val end = awaitTerminal(id)
        assertEquals(EngineEventKindMsg.FAILURE, end.kind)
        assertEquals("cancelled", end.failure!!.code)
        assertTrue("no .part left: ${partFiles().map { it.name }}", partFiles().isEmpty())
        assertFalse(ProxyRegistry.proxyFile("fp-cancel", paths).exists())
        assertEquals(ProxyStatusMsg.NO_PROXY, ProxyRegistry.status("fp-cancel", paths))
        assertEquals(0, jobs.jobCount)
    }

    @Test
    fun proxyIsPausedWhileAnExportRunsAndCompletesAfterwards() {
        val jobs = JobRegistry(ctx, concurrency = 1)
        val coordinator = FakeExportCoordinator(jobs)
        val id = start(jobs, request("frame_counter_1080p30.mp4", "fp-export", JobPriorityMsg.BACKGROUND))
        await(".part to appear", 30_000) { partFiles().isNotEmpty() }
        assertEquals(ProxyStatusMsg.RUNNING, ProxyRegistry.status("fp-export", paths))
        coordinator.startExport("export-1")
        await("the proxy to stop", 30_000) { jobs.state(id) == JobRegistry.State.QUEUED && partFiles().isEmpty() }
        assertEquals(1, jobs.restarts(id))
        assertEquals(ProxyStatusMsg.QUEUED, ProxyRegistry.status("fp-export", paths))
        assertEquals("not a cancel: no terminal event", null, terminal(id))
        // It stays paused while the export runs.
        Thread.sleep(1_500)
        assertEquals(JobRegistry.State.QUEUED, jobs.state(id))
        assertTrue(partFiles().isEmpty())
        assertFalse(ProxyRegistry.proxyFile("fp-export", paths).exists())
        coordinator.finishExport("export-1")
        val end = awaitTerminal(id)
        assertEquals(EngineEventKindMsg.JOB_DONE, end.kind)
        val proxy = VideoTrack.read(File(end.jobDone!!.asset!!.path))
        assertSamePts(VideoTrack.read(source("frame_counter_1080p30.mp4")), proxy, "restarted proxy")
        assertEquals(ProxyStatusMsg.READY, ProxyRegistry.status("fp-export", paths))
    }

    @Test
    fun hdrSourceGivesAnSdrProxyOrATypedFailure() {
        val codecs = ctx.deviceProfile.codecs()
        val canDecode = codecs.hasTenBitDecoder(MediaFormat.MIMETYPE_VIDEO_HEVC)
        val jobs = JobRegistry(ctx, concurrency = 1)
        val id = start(jobs, request("hlg_10bit_720p.mov", "fp-hlg"))
        val end = awaitTerminal(id)
        Log.i(TAG, "HLG proxy on API ${android.os.Build.VERSION.SDK_INT}: 10-bit HEVC decoder=$canDecode, tone map ${ctx.deviceProfile.toneMapping()} -> ${end.kind} ${end.failure?.code}")
        if (end.kind == EngineEventKindMsg.JOB_DONE) {
            val proxy = VideoTrack.read(File(end.jobDone!!.asset!!.path))
            assertEquals(MediaFormat.MIMETYPE_VIDEO_AVC, proxy.mime)
            assertTrue("SDR transfer: ${proxy.colorTransfer}", proxy.colorTransfer == null || proxy.colorTransfer == MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            assertEquals(90, proxy.ptsUs.size)
        } else {
            assertNotNull(end.failure)
            assertTrue(
                "typed failure: ${end.failure!!.code}",
                end.failure!!.code in setOf("unsupportedMedia", "decoderInitFailed", "decodeFailed"),
            )
            assertEquals("fp-hlg", end.failure!!.mediaFingerprint)
            assertEquals(ProxyStatusMsg.FAILED, ProxyRegistry.status("fp-hlg", paths))
            assertFalse(ProxyRegistry.proxyFile("fp-hlg", paths).exists())
        }
        assertTrue(partFiles().isEmpty())
    }
}
