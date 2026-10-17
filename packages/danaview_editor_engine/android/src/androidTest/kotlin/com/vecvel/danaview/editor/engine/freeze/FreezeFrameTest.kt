// OWNER: AND-06
//
// Freeze-frame stills on the emulator (BUILD_PLAN AND-06; ARCH §11.5 D-04, §15), with the
// production decoder choice (FrameExtractor default, software retry on a wrong frame):
// - the PNG at the Dart path carries the barcode of exactly the requested frame: frame starts at
//   plan grid times timeOfFrame(k) (30, 24, 60 fps), frame middles, the 500 µs rule-frame tolerance
//   on both sides, the first and last frames, a 0.5 s held VFR frame, and the rotated source
//   (upright 720x1280);
// - through the JobRegistry: jobDone carries the asset (path, size, no duration);
// - cancel leaves neither the still nor `<path>.part`; a missing source fails with mediaOffline,
//   an output outside the roots with permissionDenied.

package com.vecvel.danaview.editor.engine.freeze

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class FreezeFrameTest {
    companion object {
        private lateinit var engine: FreezeEngine

        @BeforeClass
        @JvmStatic
        fun setUp() {
            engine = FreezeEngine("freeze-test")
        }

        @AfterClass
        @JvmStatic
        fun tearDown() = engine.close()
    }

    private fun freeze(fixture: String, timeUs: Long, name: String): File {
        val out = engine.still(name)
        val control = FreezeControl()
        val asset = engine.ctx.freezeFrames.write(FreezeFixtures.file(fixture).absolutePath, timeUs, out, control)
        assertEquals(out.absolutePath, asset.path)
        assertEquals(out.length(), asset.sizeBytes)
        assertNull(asset.durationUs)
        assertTrue(out.isFile)
        assertFalse("no partial file stays", File(out.path + ".part").exists())
        assertEquals(1.0, control.lastProgress, 0.0)
        return out
    }

    private fun assertFrame(fixture: String, timeUs: Long, expected: Int, name: String) {
        val png = freeze(fixture, timeUs, name)
        assertEquals("$fixture at $timeUs µs", expected, FreezeFixtures.barcode(png))
    }

    @Test
    fun stillIsTheRequestedFrameOn1080p30() {
        for (k in intArrayOf(0, 1, 2, 29, 30, 77, 160, 238, 239)) {
            assertFrame("frame_counter_1080p30.mp4", FreezeFixtures.timeOfFrame(k, 30), k, "c30_$k")
        }
        assertEquals(Pair(1920, 1080), FreezeFixtures.size(engine.still("c30_0")))
        // Frame middles.
        for (k in intArrayOf(5, 119)) assertFrame("frame_counter_1080p30.mp4", FreezeFixtures.pts(k, 30) + 16_000, k, "mid30_$k")
    }

    @Test
    fun ruleFrameToleranceIs500MicrosecondsBeforeAFrame() {
        val k = 90
        val p = FreezeFixtures.pts(k, 30)
        assertFrame("frame_counter_1080p30.mp4", p - 400, k, "eps_in")
        assertFrame("frame_counter_1080p30.mp4", p - 600, k - 1, "eps_out")
    }

    @Test
    fun stillIsTheRequestedFrameOnOtherGrids() {
        for (k in intArrayOf(1, 2, 47, 100, 191)) assertFrame("frame_counter_720p24.mp4", FreezeFixtures.timeOfFrame(k, 24), k, "c24_$k")
        for (k in intArrayOf(1, 59, 301, 479)) assertFrame("frame_counter_720p60.mp4", FreezeFixtures.timeOfFrame(k, 60), k, "c60_$k")
    }

    @Test
    fun heldVfrFrameAndFrameMiddles() {
        val ticks = FreezeFixtures.vfrTicks()
        // Frame 60 is held for 0.5 s (300 ticks).
        assertFrame("vfr_720p.mp4", ticks[60] * 1_000_000 / 600 + 250_000, 60, "vfr_held")
        for (k in intArrayOf(3, 4, 61, 100)) {
            val mid = (ticks[k] + ticks[k + 1]) * 1_000_000 / 1_200
            assertFrame("vfr_720p.mp4", mid, k, "vfr_$k")
        }
    }

    @Test
    fun rotatedSourceIsFrozenUpright() {
        val png = freeze("rotated_90.mov", FreezeFixtures.timeOfFrame(45, 30), "rotated")
        assertEquals(Pair(720, 1280), FreezeFixtures.size(png))
        assertEquals(45, FreezeFixtures.barcode(png))
    }

    @Test
    fun freezeJobThroughTheRegistry() {
        val out = engine.still("registry")
        val id = engine.start(
            JobRequestMsg(
                kind = JobKindMsg.FREEZE,
                media = ResolvedMediaMsg(uri = FreezeFixtures.file("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-freeze", isProxy = false),
                priority = JobPriorityMsg.INTERACTIVE,
                sourceTimeUs = 4_000_000,
                outputPath = out.absolutePath,
            ),
        )
        val end = engine.awaitTerminal(id)
        assertEquals(EngineEventKindMsg.JOB_DONE, end.kind)
        assertEquals(JobKindMsg.FREEZE, end.jobDone!!.kind)
        assertEquals(out.absolutePath, end.jobDone!!.asset!!.path)
        assertEquals(120, FreezeFixtures.barcode(out))
    }

    @Test
    fun cancelLeavesNothingBehind() {
        // Cancel before the extraction: the job stops without writing.
        val out = engine.still("cancelled")
        val control = FreezeControl().also { it.cancel() }
        try {
            engine.ctx.freezeFrames.write(FreezeFixtures.file("frame_counter_1080p30.mp4").absolutePath, 1_000_000, out, control)
            fail("a cancelled job does not finish")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.cancelled, e.code)
        }
        assertFalse(out.exists())
        assertFalse(File(out.path + ".part").exists())
        // Cancel through the registry right after the start.
        val out2 = engine.still("cancelled2")
        val id = engine.start(
            JobRequestMsg(
                kind = JobKindMsg.FREEZE,
                media = ResolvedMediaMsg(uri = FreezeFixtures.file("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp-cancel", isProxy = false),
                priority = JobPriorityMsg.INTERACTIVE,
                sourceTimeUs = 2_000_000,
                outputPath = out2.absolutePath,
            ),
        )
        engine.ctx.jobs.cancel(id)
        val end = engine.awaitTerminal(id)
        if (end.kind == EngineEventKindMsg.FAILURE) {
            assertEquals(EngineErrorCode.cancelled.name, end.failure!!.code)
            assertFalse(out2.exists())
        }
        assertFalse(File(out2.path + ".part").exists())
    }

    @Test
    fun failuresAreTyped() {
        val missing = JobRequestMsg(
            kind = JobKindMsg.FREEZE,
            media = ResolvedMediaMsg(uri = File(engine.paths.media, "gone.mp4").absolutePath, fingerprint = "fp-gone", isProxy = false),
            priority = JobPriorityMsg.INTERACTIVE,
            sourceTimeUs = 0,
            outputPath = engine.still("gone").absolutePath,
        )
        try {
            engine.ctx.freezeFrames.run(missing, FreezeControl())
            fail("a missing source fails")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.mediaOffline, e.code)
            assertEquals("fp-gone", e.mediaFingerprint)
        }
        val outside = missing.copy(
            media = ResolvedMediaMsg(uri = FreezeFixtures.file("frame_counter_1080p30.mp4").absolutePath, fingerprint = "fp", isProxy = false),
            outputPath = File(engine.ctx.appContext.cacheDir, "elsewhere/still.png").absolutePath,
        )
        try {
            engine.ctx.freezeFrames.run(outside, FreezeControl())
            fail("an output outside the roots is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.permissionDenied, e.code)
        }
    }
}
