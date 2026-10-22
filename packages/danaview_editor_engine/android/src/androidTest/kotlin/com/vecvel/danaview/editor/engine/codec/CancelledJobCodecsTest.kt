// OWNER: QA-05 D9
//
// D9 regression: cancelled engine jobs give their codecs back. Cycles of reverse, proxy, freeze
// and export jobs, each cancelled mid-run through the production entry points (JobRegistry,
// ExportCoordinator), then: the process's codec clients (ResourceManagerService), playback,
// Transformer and MediaCodec looper threads are back at the baseline, a new AAC encoder is created
// within a bound (the D9 stall was MediaCodec.createByCodecName waiting in
// reclaimResourcesFromClientsPendingRemoval), and a full export completes within a bound.
// Emulator times are emulator times; the bounds are generous on purpose.

package com.vecvel.danaview.editor.engine.codec

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
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
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CancelledJobCodecsTest {
    private lateinit var ctx: EngineContext
    private lateinit var paths: Paths
    private val events: MutableList<EngineEventMsg> = Collections.synchronizedList(ArrayList())
    private val sink = EngineEventSink { events.add(it) }
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
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.attach(sink) }
        exports = ExportHarness("d9")
    }

    @After
    fun tearDown() {
        exports.close()
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.detach(sink) }
        ctx.threads.shutdown()
        File(TestFixtures.targetContext.cacheDir, "d9").deleteRecursively()
    }

    private fun media(name: String) = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    private fun start(request: JobRequestMsg): String {
        val latch = CountDownLatch(1)
        var id: Result<String>? = null
        ctx.jobs.start(request) {
            id = it
            latch.countDown()
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        return id!!.getOrThrow()
    }

    private fun terminal(jobId: String): EngineEventMsg? = synchronized(events) {
        events.lastOrNull { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }
    }

    private fun progress(jobId: String): Double = synchronized(events) {
        events.filter { it.jobId == jobId && it.kind == EngineEventKindMsg.PROGRESS }.maxOfOrNull { it.progress ?: 0.0 } ?: 0.0
    }

    private fun awaitTerminal(jobId: String, timeoutMs: Long = 120_000): EngineEventMsg {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            terminal(jobId)?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("job $jobId did not end within $timeoutMs ms (${CodecCensus.take()})")
    }

    /** Starts [request], cancels it once it has progressed to [atProgress] (or after [maxWaitMs]) and waits for its end. */
    private fun startAndCancel(request: JobRequestMsg, atProgress: Double, maxWaitMs: Long): EngineEventMsg {
        val id = start(request)
        val deadline = System.currentTimeMillis() + maxWaitMs
        while (progress(id) < atProgress && terminal(id) == null && System.currentTimeMillis() < deadline) Thread.sleep(10)
        ctx.jobs.cancel(id)
        val end = awaitTerminal(id)
        Log.i(TAG, "${request.kind} ${end.failure?.code ?: "done"}: at its terminal event ${CodecCensus.take()}")
        return end
    }

    private fun reverse(cycle: Int) = JobRequestMsg(
        kind = JobKindMsg.REVERSE,
        media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-d9-rev", isProxy = false),
        priority = JobPriorityMsg.INTERACTIVE,
        sourceStartUs = 0,
        sourceEndUs = 6_000_000,
        outputPath = File(paths.derived, "d9_rev_$cycle.mp4").absolutePath,
    )

    private fun proxy(cycle: Int): JobRequestMsg {
        val fp = "fp-d9-proxy-$cycle"
        ProxyRegistry.proxyFile(fp, paths).delete()
        return JobRequestMsg(
            kind = JobKindMsg.PROXY,
            media = ResolvedMediaMsg(uri = media("frame_counter_1080p30.mp4").absolutePath, fingerprint = fp, isProxy = false),
            priority = JobPriorityMsg.INTERACTIVE,
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
        Log.i(TAG, "export cycle $cycle: ${end.failure?.code ?: "done"} in ${end.wallMs} ms; at its terminal event ${CodecCensus.take()}")
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
            val rev = startAndCancel(reverse(cycle), atProgress = 0.05 + 0.1 * (cycle % 3), maxWaitMs = 20_000)
            val prx = startAndCancel(proxy(cycle), atProgress = 0.02 + 0.1 * (cycle % 3), maxWaitMs = 20_000)
            val frz = startAndCancel(freeze(cycle), atProgress = 1.1, maxWaitMs = 40L * (cycle % 4))
            exportAndCancel(cycle, afterMs = 300L + 400L * (cycle % 3))
            Log.i(TAG, "cycle $cycle: reverse ${rev.failure?.code ?: "done"}, proxy ${prx.failure?.code ?: "done"}, freeze ${frz.failure?.code ?: "done"}; ${CodecCensus.take()}")
        }
        val after = CodecCensus.settle(SETTLE_MS) { c ->
            c.clients.size <= baseline.clients.size &&
                c.playbackThreads <= baseline.playbackThreads &&
                c.codecLoopers <= baseline.codecLoopers &&
                c.transformerThreads <= baseline.transformerThreads
        }
        Log.i(TAG, "after $CYCLES cycles: $after")
        assertEquals("codec clients after the cancelled jobs ($after)", baseline.clients, after.clients)
        assertTrue("playback threads back at the baseline ($baseline -> $after)", after.playbackThreads <= baseline.playbackThreads)
        assertTrue("MediaCodec loopers back at the baseline ($baseline -> $after)", after.codecLoopers <= baseline.codecLoopers)
        assertTrue("Transformer threads back at the baseline ($baseline -> $after)", after.transformerThreads <= baseline.transformerThreads)

        val aacMs = timedAacEncoder(ENCODER_BOUND_MS)
        assertNotNull("an AAC encoder is created within $ENCODER_BOUND_MS ms after the cycles (${CodecCensus.take()})", aacMs)
        Log.i(TAG, "AAC encoder created in $aacMs ms (emulator)")

        val t0 = System.nanoTime()
        val full = exports.export(exportPlan(), settings(fps = 30), "after_cycles")
        val ms = (System.nanoTime() - t0) / 1_000_000
        full.requireResult()
        assertTrue("an export after the cycles completes within $EXPORT_BOUND_MS ms (took $ms)", ms <= EXPORT_BOUND_MS)
        Log.i(TAG, "export after the cycles: $ms ms (emulator); ${CodecCensus.take()}")
    }

    companion object {
        private const val TAG = "DanaviewD9Test"
        private const val CYCLES = 6
        private const val SETTLE_MS = 10_000L
        private const val ENCODER_BOUND_MS = 5_000L
        private const val EXPORT_BOUND_MS = 120_000L
    }
}
