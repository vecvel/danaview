@file:OptIn(UnstableApi::class)
// OWNER: QA-05 D9
//
// D9 regression tests: engine jobs give their codecs back before they report their end, and an
// export does not create its codecs while others are still releasing theirs.
//
// 1. Cycles of reverse, proxy, freeze and export jobs, each cancelled mid-run through the
//    production entry points (JobRegistry, ExportCoordinator). At each job's terminal event (seen
//    in the event sink, on delivery) no Media3 owner of a codec is left: no ExoPlayer playback
//    thread (Transformer asset loaders, FrameExtractor) and no Transformer internal thread. The
//    platform's own teardown is asynchronous on API 34+ (MediaCodec.release() returns while
//    ResourceManagerService still lists the client "pending removal"), so the codec clients and
//    MediaCodec loopers only have to be gone within a bound after the event. After the cycles, the
//    counts are at the baseline, a new AAC encoder is created within a bound (the D9 stall was
//    createByCodecName waiting in reclaimResourcesFromClientsPendingRemoval) and a full export
//    completes within a bound.
// 2. The handover: a proxy job (paused by an export) is running with its codecs when an export
//    starts. The export's first encoder must not be created before the proxy has stopped and its
//    Transformer thread is gone.
// Emulator times are emulator times; the bounds are generous on purpose.

package com.vecvel.danaview.editor.engine.codec

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.metrics.LogSessionId
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Codec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineEventSink
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.ExportPlans
import com.vecvel.danaview.editor.engine.export.settings
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.ProxyRegistry
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.harness.PerfGate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CancelledJobCodecsTest {
    private lateinit var ctx: EngineContext
    private lateinit var paths: Paths
    private val events: MutableList<EngineEventMsg> = Collections.synchronizedList(ArrayList())

    /** Thread names at each job's terminal event, taken in the sink when the event is delivered. */
    private val atTerminal = ConcurrentHashMap<String, Map<String, Int>>()

    private fun isTerminal(e: EngineEventMsg) = e.kind == EngineEventKindMsg.JOB_DONE || e.kind == EngineEventKindMsg.FAILURE

    private val sink = EngineEventSink { e ->
        if (isTerminal(e)) e.jobId?.let { atTerminal.putIfAbsent(it, CodecCensus.threadNames()) }
        events.add(e)
    }
    private val exportSink = EngineEventSink { e ->
        if (isTerminal(e)) e.jobId?.let { atTerminal.putIfAbsent(it, CodecCensus.threadNames()) }
    }
    private lateinit var exports: ExportHarness

    @Before
    fun setUp() {
        val app = TestFixtures.targetContext.applicationContext
        ctx = EngineContext(app, EngineThreads.android())
        val cache = File(app.cacheDir, "d9/danaview/editor")
        val support = File(app.filesDir, "d9/danaview/editor")
        cache.deleteRecursively()
        support.parentFile?.deleteRecursively()
        paths = Paths.fromDart(cache.absolutePath, support.absolutePath)
        ctx.installRoots(paths)
        exports = ExportHarness("d9")
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            ctx.events.attach(sink)
            exports.ctx.events.attach(exportSink)
        }
    }

    @After
    fun tearDown() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            ctx.events.detach(sink)
            exports.ctx.events.detach(exportSink)
        }
        exports.close()
        ctx.threads.shutdown()
        File(TestFixtures.targetContext.cacheDir, "d9").deleteRecursively()
    }

    private fun media(name: String) = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    private fun start(jobs: com.vecvel.danaview.editor.engine.core.JobRegistry, request: JobRequestMsg): String {
        val latch = CountDownLatch(1)
        var id: Result<String>? = null
        jobs.start(request) {
            id = it
            latch.countDown()
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        return id!!.getOrThrow()
    }

    private fun terminal(jobId: String, list: List<EngineEventMsg> = events): EngineEventMsg? = synchronized(list) {
        list.lastOrNull { it.jobId == jobId && isTerminal(it) }
    }

    private fun progress(jobId: String, list: List<EngineEventMsg> = events): Double = synchronized(list) {
        list.filter { it.jobId == jobId && it.kind == EngineEventKindMsg.PROGRESS }.maxOfOrNull { it.progress ?: 0.0 } ?: 0.0
    }

    private fun awaitTerminal(jobId: String, list: List<EngineEventMsg> = events, timeoutMs: Long = 120_000): EngineEventMsg {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            terminal(jobId, list)?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("job $jobId did not end within $timeoutMs ms (${CodecCensus.take()})")
    }

    /** Starts [request], cancels it once it has progressed to [atProgress] (or after [maxWaitMs]) and waits for its end. */
    private fun startAndCancel(request: JobRequestMsg, atProgress: Double, maxWaitMs: Long): EngineEventMsg {
        val id = start(ctx.jobs, request)
        val deadline = System.currentTimeMillis() + maxWaitMs
        while (progress(id) < atProgress && terminal(id) == null && System.currentTimeMillis() < deadline) Thread.sleep(10)
        ctx.jobs.cancel(id)
        val end = awaitTerminal(id)
        checkReleased(id, "${request.kind} ${end.failure?.code ?: "done"}")
        return end
    }

    private val problems = ArrayList<String>()

    /**
     * At [jobId]'s terminal event no Media3 codec owner may be alive (strict); the platform's async
     * codec teardown must finish within [CODEC_SETTLE_MS] after it.
     */
    private fun checkReleased(jobId: String, what: String) {
        // The harness's own sink may see the event a moment before ours (both run on delivery).
        val waitUntil = System.currentTimeMillis() + 2_000
        while (atTerminal[jobId] == null && System.currentTimeMillis() < waitUntil) Thread.sleep(5)
        val threads = requireNotNull(atTerminal[jobId]) { "no terminal snapshot for $jobId" }
        val at = CodecCensus(emptyList(), threads)
        val t0 = System.currentTimeMillis()
        val settled = CodecCensus.settle(CODEC_SETTLE_MS) { it.clients.isEmpty() && it.codecLoopers == 0 }
        val settleMs = System.currentTimeMillis() - t0
        val line = "$what: at the terminal event playback=${at.playbackThreads} transformer=${at.transformerThreads} " +
            "codecLoopers=${at.codecLoopers}; platform teardown done after $settleMs ms ($settled)"
        Log.i(TAG, line)
        if (at.playbackThreads != 0 || at.transformerThreads != 0) problems += "$line: a Media3 codec owner was alive at the terminal event"
        if (settled.clients.isNotEmpty() || settled.codecLoopers != 0) problems += "$line: codecs not released within $CODEC_SETTLE_MS ms"
    }

    private fun reverse(cycle: Int) = JobRequestMsg(
        kind = JobKindMsg.REVERSE,
        media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-d9-rev", isProxy = false),
        priority = JobPriorityMsg.INTERACTIVE,
        sourceStartUs = 0,
        sourceEndUs = 6_000_000,
        outputPath = File(paths.derived, "d9_rev_$cycle.mp4").absolutePath,
    )

    private fun proxy(fp: String, p: Paths, priority: JobPriorityMsg = JobPriorityMsg.INTERACTIVE): JobRequestMsg {
        ProxyRegistry.proxyFile(fp, p).delete()
        return JobRequestMsg(
            kind = JobKindMsg.PROXY,
            media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = fp, isProxy = false),
            priority = priority,
        )
    }

    private fun freeze(cycle: Int) = JobRequestMsg(
        kind = JobKindMsg.FREEZE,
        media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-d9-freeze", isProxy = false),
        priority = JobPriorityMsg.INTERACTIVE,
        sourceTimeUs = 1_000_000L + cycle * 100_000L,
        outputPath = File(paths.projects, "p1/assets/stills/d9_$cycle.png").absolutePath,
    )

    /** A 4 s 1280x720 30 fps export of the 1080p30 counter with a tone under it (video and audio codecs). */
    private fun exportPlan(): RenderPlan {
        val g = FrameGrid.of(30)
        val frames = 120L
        val dur = g.timeOfFrame(frames)
        return RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = dur,
            assets = mapOf(
                "md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_1080p30.mp4"), fp = "c30", w = 1920, h = 1080, durUs = 8_000_000),
                "md_tone" to PlanAsset(PlanAssetKind.AUDIO, ExportPlans.media("tone_1khz.wav"), fp = "tone", durUs = 10_000_000),
            ),
            layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, frames, 0, 30, base = PlanSize(1280.0, 720.0))),
            audio = listOf(AudioSeg(id = "it_tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 0.5))),
        )
    }

    private fun exportAndCancel(cycle: Int, afterMs: Long) {
        val id = exports.start(exportPlan(), settings(fps = 30), exports.output("cancel_$cycle"))
        val deadline = System.currentTimeMillis() + afterMs
        while (System.currentTimeMillis() < deadline && exports.events.none { it.jobId == id && it.kind != EngineEventKindMsg.EXPORT_PROGRESS }) Thread.sleep(10)
        exports.cancel(id)
        val end = exports.await(id, timeoutSec = 120)
        checkReleased(id, "EXPORT ${end.failure?.code ?: "done"} (${end.wallMs} ms)")
    }

    /** Creates (and releases) an AAC encoder on a fresh thread; the time it took, or null when it did not return within [boundMs]. */
    private fun timedAacEncoder(boundMs: Long): Long? {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 48_000, 2).apply { setInteger(MediaFormat.KEY_BIT_RATE, 128_000) }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)!!
        val done = CountDownLatch(1)
        val t0 = System.nanoTime()
        var took = 0L
        Thread({
            val codec = MediaCodec.createByCodecName(name)
            took = (System.nanoTime() - t0) / 1_000_000
            codec.release()
            done.countDown()
        }, "d9-aac-probe").start()
        return if (done.await(boundMs, TimeUnit.MILLISECONDS)) took else null
    }

    @Test
    fun cancelledJobsReleaseTheirCodecsAndALaterEncoderStarts() {
        val baseline = CodecCensus.settle(5_000) { it.clients.isEmpty() }
        Log.i(TAG, "baseline: $baseline")
        for (cycle in 0 until CYCLES) {
            startAndCancel(reverse(cycle), atProgress = 0.05 + 0.1 * (cycle % 3), maxWaitMs = 20_000)
            startAndCancel(proxy("fp-d9-proxy-$cycle", paths), atProgress = 0.02 + 0.1 * (cycle % 3), maxWaitMs = 20_000)
            startAndCancel(freeze(cycle), atProgress = 1.1, maxWaitMs = 40L * (cycle % 4))
            exportAndCancel(cycle, afterMs = 300L + 400L * (cycle % 3))
        }
        val after = CodecCensus.settle(CODEC_SETTLE_MS) { c ->
            c.clients.size <= baseline.clients.size &&
                c.playbackThreads <= baseline.playbackThreads &&
                c.codecLoopers <= baseline.codecLoopers &&
                c.transformerThreads <= baseline.transformerThreads
        }
        Log.i(TAG, "after $CYCLES cycles: $after")
        assertEquals("every job released its codecs before its end, and the platform within a bound", emptyList<String>(), problems)
        assertEquals("codec clients after the cancelled jobs ($after)", baseline.clients, after.clients)
        assertTrue("playback threads back at the baseline ($baseline -> $after)", after.playbackThreads <= baseline.playbackThreads)
        assertTrue("MediaCodec loopers back at the baseline ($baseline -> $after)", after.codecLoopers <= baseline.codecLoopers)
        assertTrue("Transformer threads back at the baseline ($baseline -> $after)", after.transformerThreads <= baseline.transformerThreads)

        // Bounds are device numbers with DV_PERF_STRICT=1, 4x on a loaded emulator; that an encoder
        // can be created and the export completes is checked in both modes.
        val encoderBound = PerfGate.boundMs(ENCODER_BOUND_MS)
        val aacMs = timedAacEncoder(encoderBound)
        assertNotNull("an AAC encoder is created within $encoderBound ms after the cycles (${PerfGate.mode}; ${CodecCensus.take()})", aacMs)
        Log.i(TAG, "AAC encoder created in $aacMs ms (emulator)")

        val t0 = System.nanoTime()
        val full = exports.export(exportPlan(), settings(fps = 30), "after_cycles")
        val ms = (System.nanoTime() - t0) / 1_000_000
        full.requireResult()
        val exportBound = PerfGate.boundMs(EXPORT_BOUND_MS)
        assertTrue("an export after the cycles completes within $exportBound ms (took $ms, ${PerfGate.mode})", ms <= exportBound)
        Log.i(TAG, "export after the cycles: $ms ms (emulator); ${CodecCensus.take()}")
    }

    /** Wraps the export's encoder factory and records the threads when the export's first encoder is created. */
    private class FirstEncoderProbe(private val base: Codec.EncoderFactory) : Codec.EncoderFactory {
        @Volatile var threads: Map<String, Int>? = null

        private fun note() {
            if (threads == null) threads = CodecCensus.threadNames()
        }

        override fun createForAudioEncoding(format: Format, logSessionId: LogSessionId?): Codec {
            note()
            return base.createForAudioEncoding(format, logSessionId)
        }

        override fun createForVideoEncoding(format: Format, logSessionId: LogSessionId?): Codec {
            note()
            return base.createForVideoEncoding(format, logSessionId)
        }

        override fun isVideoFormatSupported(format: Format): Boolean = base.isVideoFormatSupported(format)

        override fun audioNeedsEncoding(): Boolean = base.audioNeedsEncoding()

        override fun videoNeedsEncoding(): Boolean = base.videoNeedsEncoding()
    }

    @Test
    fun anExportStartsItsCodecsAfterThePausedJobReleasedItsOwn() {
        val proxyEvents = exports.events
        repeat(HANDOVER_RUNS) { run ->
            var probe: FirstEncoderProbe? = null
            exports.coordinator.encoderFactoryDecorator = { base -> FirstEncoderProbe(base).also { probe = it } }
            // A proxy job (paused during exports) running with its Transformer and codecs.
            val proxyId = start(exports.ctx.jobs, proxy("fp-d9-handover-$run", exports.paths, JobPriorityMsg.NORMAL))
            val deadline = System.currentTimeMillis() + 30_000
            while (progress(proxyId, proxyEvents) < 0.05 && terminal(proxyId, proxyEvents) == null && System.currentTimeMillis() < deadline) Thread.sleep(10)
            assertTrue("the proxy is transcoding before the export starts", progress(proxyId, proxyEvents) >= 0.05 && terminal(proxyId, proxyEvents) == null)
            assertTrue("the proxy's Transformer thread runs", (CodecCensus.threadNames()["danaview-proxy"] ?: 0) > 0)

            val o = exports.export(exportPlan(), settings(fps = 30), "handover_$run")
            o.requireResult()
            val seen = requireNotNull(probe?.threads) { "the export created no encoder" }
            Log.i(TAG, "handover run $run: at the export's first encoder proxy threads=${seen["danaview-proxy"] ?: 0} transformer=${seen.filterKeys { it.startsWith("Transformer:Int") }.values.sum()}")
            assertEquals(
                "run $run: the paused proxy's Transformer thread is gone when the export creates its first encoder",
                0,
                seen["danaview-proxy"] ?: 0,
            )
            // The proxy resumes after the export and is cancelled for the next run.
            exports.ctx.jobs.cancel(proxyId)
            awaitTerminal(proxyId, proxyEvents)
            exports.coordinator.encoderFactoryDecorator = null
        }
    }

    companion object {
        private const val TAG = "DanaviewD9Test"
        private const val CYCLES = 6
        private const val HANDOVER_RUNS = 3

        /** The platform's async codec teardown after release() (API 34+), emulator. */
        private const val CODEC_SETTLE_MS = 5_000L
        private const val ENCODER_BOUND_MS = 5_000L
        private const val EXPORT_BOUND_MS = 120_000L
    }
}
