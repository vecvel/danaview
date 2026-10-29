// OWNER: AND-06
//
// The source-frame cache on the emulator (BUILD_PLAN AND-06; ARCH §12.2, §13.3, §15):
// - frames are the exact rule frames (barcodes), bounded to a long side on request, upright for
//   the rotated source; hits do not decode;
// - sampleColor (3x3 average of the pre-key source) is within ±2/255 of the reference: the same
//   frame decoded by the platform software decoder and converted with BT.709 (FreezeTestSupport);
// - memory: the cache never holds more than its budget (LRU eviction, oversize frames returned but
//   not kept), the engine's cache uses the tier budget, trims shrink it (memoryPressure to a
//   quarter, background to nothing) and close the extractor, which also closes after 5 s idle;
// - look stills: a null look is the unprocessed frame at the height; a LookStill renders through
//   AND-09's LayerLookEffect (the API-03 every-effect layer with its LUT); an identity look matches
//   the unprocessed still and the looks of one call switch correctly;
// - async requests complete, and a cancelled one ends `cancelled`.
// Waits (extractor closes, async completions) are timing: their limits apply as written only with
// DV_PERF_STRICT=1 and are 4x longer on a loaded emulator (harness/PerfGate.kt); every frame,
// colour, budget and decode-count check is the same in both modes.

package com.vecvel.danaview.editor.engine.freeze

import android.graphics.Bitmap
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.PerfGate
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.preview.LookStill
import com.vecvel.danaview.editor.engine.preview.SourceFrameCache
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class SourceFrameCacheTest {
    companion object {
        private const val TAG = "DanaviewFreezeTest"
        private lateinit var engine: FreezeEngine
        private const val MB = 1024L * 1024L

        @BeforeClass
        @JvmStatic
        fun setUp() {
            engine = FreezeEngine("frames-test")
        }

        @AfterClass
        @JvmStatic
        fun tearDown() = engine.close()
    }

    private val counter by lazy { FreezeFixtures.file("frame_counter_1080p30.mp4").absolutePath }

    private fun time(k: Int) = FreezeFixtures.timeOfFrame(k, 30)

    @Test
    fun framesAreExactAndHitsDoNotDecode() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        for (k in intArrayOf(0, 1, 77, 239)) {
            val frame = cache.frame(counter, "fp-counter", time(k))
            assertEquals(1920, frame.width)
            assertEquals(k, FrameBarcode.decode(frame))
        }
        assertEquals(4, cache.decodeCount)
        val again = cache.frame(counter, "fp-counter", time(77))
        assertEquals(4, cache.decodeCount)
        assertSame(again, cache.frame(counter, "fp-counter", time(77)))
        assertEquals(77, FrameBarcode.decode(again))
        cache.removeAll()
    }

    @Test
    fun longSideBoundAndRotation() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        val small = cache.frame(counter, "fp-counter", time(160), maxLongSide = 480)
        assertEquals(480, small.width)
        assertEquals(270, small.height)
        assertEquals(160, FrameBarcode.decode(small))
        val rotated = cache.frame(FreezeFixtures.file("rotated_90.mov").absolutePath, "fp-rot", time(30), maxLongSide = 640)
        assertEquals(360, rotated.width)
        assertEquals(640, rotated.height)
        assertEquals(30, FrameBarcode.decode(rotated))
        val notEnlarged = cache.frame(FreezeFixtures.file("sample_h264_aac.mkv").absolutePath, "fp-mkv", 1_000_000, maxLongSide = 1280)
        assertEquals(640, notEnlarged.width)
        assertEquals(25, FrameBarcode.decode(notEnlarged))
        cache.removeAll()
    }

    @Test
    fun sampledColourMatchesTheReferenceFrame() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        val file = FreezeFixtures.file("frame_counter_1080p30.mp4")
        val reference = YuvReference.decode(file, FreezeFixtures.pts(160, 30))
        assertEquals("the reference is frame 160", 160, YuvReference.barcode(reference))
        // Flat regions: backdrop, lower calm area, digits area, barcode cells 0 (white) and 1 (black).
        val points = listOf(0.25 to 0.5, 0.75 to 0.8, 0.5 to 0.3, 0.0179 to 0.05, 0.0536 to 0.05)
        // The sample is the key shader's input: the frame as Media3's GL pipeline converts it. The
        // reference is computed with both matrices; the platform's GL sampler decides which applies
        // (ARCH §13 expects BT.709; the x86_64 emulator's sampler converts with BT.601, measured).
        var worst709 = 0.0
        var worst601 = 0.0
        for ((x, y) in points) {
            val want709 = reference.average(x, y)
            val want601 = reference.average(x, y, bt601 = true)
            val got = cache.sampleColor(file.absolutePath, "fp-counter", 5_350_000, x, y)
            val c = doubleArrayOf(got.red, got.green, got.blue)
            for (i in 0 until 3) {
                worst709 = maxOf(worst709, kotlin.math.abs(c[i] - want709[i]))
                worst601 = maxOf(worst601, kotlin.math.abs(c[i] - want601[i]))
            }
            Log.i(TAG, "sampleColor at ($x, $y) [emulator]: got (%.4f, %.4f, %.4f) BT.709 ref (%.4f, %.4f, %.4f) BT.601 ref (%.4f, %.4f, %.4f)".format(
                got.red, got.green, got.blue, want709[0], want709[1], want709[2], want601[0], want601[1], want601[2]))
            assertEquals(1.0, got.alpha, 1e-9)
        }
        Log.i(TAG, "sampleColor worst |d| vs BT.709 %.2f/255, vs BT.601 %.2f/255 [emulator]".format(worst709 * 255, worst601 * 255))
        val worst = minOf(worst709, worst601)
        assertTrue("every point within ±2/255 of the reference of the platform's matrix (worst %.2f/255)".format(worst * 255), worst <= 2.0 / 255)
        assertEquals("one decode serves every sample of the frame", 1, cache.decodeCount)
        cache.removeAll()
    }

    @Test
    fun cacheIsBoundedByItsBudget() {
        val frameBytes = 1920L * 1080 * 4
        val cache = SourceFrameCache(engine.ctx, 2 * frameBytes + MB)
        for (k in 10 until 16) {
            cache.frame(counter, "fp-counter", time(k))
            assertTrue("never over budget: ${cache.totalBytes}", cache.totalBytes <= cache.budgetBytes)
        }
        assertEquals(2, cache.count)
        // The two most recent frames are hits, an older one decodes again.
        val decodes = cache.decodeCount
        cache.frame(counter, "fp-counter", time(15))
        cache.frame(counter, "fp-counter", time(14))
        assertEquals(decodes, cache.decodeCount)
        cache.frame(counter, "fp-counter", time(10))
        assertEquals(decodes + 1, cache.decodeCount)
        // A frame larger than the whole budget is returned but not kept.
        val tiny = SourceFrameCache(engine.ctx, 4 * MB)
        val big = tiny.frame(counter, "fp-counter", time(20))
        assertEquals(20, FrameBarcode.decode(big))
        assertEquals(0, tiny.count)
        assertEquals(0L, tiny.totalBytes)
        // The engine's cache uses the tier budget.
        assertEquals(SourceFrameCache.budgetFor(engine.ctx.deviceProfile.tier()), engine.ctx.sourceFrames.budgetBytes)
        Log.i(TAG, "tier ${engine.ctx.deviceProfile.tier()} budget ${engine.ctx.sourceFrames.budgetBytes / MB} MB [emulator]")
        cache.removeAll()
        tiny.removeAll()
    }

    @Test
    fun trimsShrinkTheCacheAndCloseTheExtractor() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        for (k in 40 until 46) cache.frame(counter, "fp-counter", time(k), maxLongSide = 960)
        assertEquals(6, cache.count)
        assertTrue(cache.hasOpenExtractor)
        cache.trim(CacheTrimLevelMsg.MEMORY_PRESSURE)
        assertTrue(cache.totalBytes <= cache.budgetBytes / 4)
        awaitTrue("extractor closed after a trim") { !cache.hasOpenExtractor }
        cache.frame(counter, "fp-counter", time(50), maxLongSide = 960)
        cache.trim(CacheTrimLevelMsg.BACKGROUND)
        assertEquals(0, cache.count)
        assertEquals(0L, cache.totalBytes)
        // Idle close.
        cache.frame(counter, "fp-counter", time(51), maxLongSide = 960)
        assertTrue(cache.hasOpenExtractor)
        awaitTrue("extractor closed after 5 s idle", 15_000) { !cache.hasOpenExtractor }
        cache.remove("fp-counter")
        assertEquals(0, cache.count)
    }

    @Test
    fun lookStillsRenderThroughTheLookEffect() {
        val plan = PlanReader.readPlan(TestFixtures.open(FixtureTree.ENGINE_API, "images/plans/effects_every_static_key.json").use { it.readBytes() })
        val layer = plan.layers.single { it.id == "it_fx0000000001#v" }
        val styled = ParamSnapshot.evaluate(layer, plan, layer.t0)
        val identity = styled.copy(adj = null, detail = null, lut = null, chroma = null, mask = null, crop = PlanCrop.FULL)
        val assets = EffectAssets { uri ->
            if (uri.endsWith(".vlut")) TestFixtures.open(FixtureTree.ENGINE_API, "images/sources/lut_33.vlut") else throw IllegalArgumentException("no fixture")
        }
        val geometry = RenderGeometry(plan.canvas.w, plan.canvas.h, 480, 270)
        fun look(params: com.vecvel.danaview.editor.engine.plan.LayerParams) = LookStill(params, layer, plan, geometry, assets)
        val cache = SourceFrameCache(engine.ctx, 64 * MB)

        val plain = cache.lookStills(counter, "fp-counter", time(15), 96, listOf(null)).single()
        assertEquals(96, plain.height)
        assertEquals(171, plain.width)

        val stills = cache.lookStills(counter, "fp-counter", time(15), 96, listOf(look(identity), look(styled), look(identity), null))
        assertEquals(4, stills.size)
        for (s in stills) assertEquals(96, s.height)
        val identityVsPlain = meanAbsDiff(stills[0], plain)
        val identityRepeat = meanAbsDiff(stills[0], stills[2])
        val styledVsIdentity = meanAbsDiff(stills[1], stills[0])
        Log.i(TAG, "look stills [emulator]: identity vs unprocessed %.2f, identity vs identity %.2f, styled vs identity %.2f (mean |d|/255)".format(identityVsPlain, identityRepeat, styledVsIdentity))
        assertTrue("an identity look is the unprocessed frame", identityVsPlain < 3.0)
        assertTrue("the binding switches back", identityRepeat < 0.5)
        assertTrue("the styled look changes the still", styledVsIdentity > 8.0)
        assertEquals(0.0, meanAbsDiff(stills[3], plain), 0.5)
        (stills + plain).forEach(Bitmap::recycle)
        cache.removeAll()
    }

    @Test
    fun asyncRequestsCompleteAndCancel() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        val latch = CountDownLatch(1)
        var result: Result<Bitmap>? = null
        cache.frameAsync(counter, "fp-counter", time(200), 640) {
            result = it
            latch.countDown()
        }
        assertTrue("async request completed", latch.await(PerfGate.boundMs(60_000), TimeUnit.MILLISECONDS))
        assertEquals(200, FrameBarcode.decode(result!!.getOrThrow()))

        val cancelled = CountDownLatch(1)
        var outcome: Result<Bitmap>? = null
        val handle = cache.frameAsync(counter, "fp-counter", time(201), 640) {
            outcome = it
            cancelled.countDown()
        }
        handle.cancel()
        assertTrue("cancelled request ended", cancelled.await(PerfGate.boundMs(60_000), TimeUnit.MILLISECONDS))
        val error = outcome!!.exceptionOrNull()
        assertNotNull(error)
        assertEquals(EngineErrorCode.cancelled, (error as EngineException).code)
        cache.removeAll()
    }

    @Test
    fun invalidArgumentsAreRefused() {
        val cache = SourceFrameCache(engine.ctx, 64 * MB)
        try {
            cache.sampleColor(counter, "fp-counter", 0, Double.NaN, 0.5)
            fail("a NaN point is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.internal, e.code)
        }
        try {
            cache.lookStills(counter, "fp-counter", 0, 0, listOf(null))
            fail("a zero height is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.internal, e.code)
        }
    }

    /** Waits for [condition]; [timeoutMs] applies with DV_PERF_STRICT=1, 4x it otherwise (a loaded worker). */
    private fun awaitTrue(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val limit = PerfGate.boundMs(timeoutMs)
        val deadline = System.currentTimeMillis() + limit
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("timed out after $limit ms (${PerfGate.mode}): $what")
            Thread.sleep(20)
        }
    }
}
