// OWNER: AND-19
//
// Multi-pass export precompose end to end on the emulator (ARCH D-45(B), §14.3; BUILD_PLAN AND-19
// acceptance criteria), through AND-11's production ExportCoordinator, which discovers the
// production PrecomposeExport by reflection; only the decoder budget is forced (environment seam).
// - The same plan exported once in one pass (budget 16 slots) and once precomposed
//   (maxVisualSequences forced to 2: 4 slots → 3 passes, two intermediates) at 24, 30 and 60 fps:
//   identical frame count on the export grid, per-frame luma SSIM ≥ 0.995, the bottom slot's
//   grid-cut barcode exact on 100% of the frames of both exports (it went through both
//   intermediates), and audio (a tone with a gain ramp plus the clap track) within QA-11's
//   ±0.5 dB per 20 ms window.
// - maxVisualSequences forced to 2: a 6-slot project is not refused (preflight ok with the
//   layersVsResolution warning) and exports in 5 passes, matching its single pass.
// - Rotated source (rotated_90.mov) in a precomposed slot matches single pass (SSIM, upright
//   barcode in its region). HDR (hlg_10bit_720p.mov) runs only where the device has a 10-bit HEVC
//   decoder and a tone-mapping path (the x86_64 emulator has neither: deferred to a device).
// - Cancel during each pass (1, 2 and the final) leaves no intermediate, no work dir and no output.
// Software-first decoders as in AND-08/AND-11 frame checks (the goldfish H.264 decoder drops
// B-pyramid frames). Times and SSIM values logged are EMULATOR measurements.

package com.vecvel.danaview.editor.engine.precompose

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.ExportWarnings
import com.vecvel.danaview.editor.engine.export.ExportedFile
import com.vecvel.danaview.editor.engine.export.settings
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import com.vecvel.danaview.editor.engine.export.ExportPlans
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class PrecomposeExportTest {
    private val harnesses = ArrayList<PrecomposeHarness>()

    private fun harness(name: String) = PrecomposeHarness(name).also {
        it.h.softwareDecoders()
        harnesses += it
    }

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
    }

    /** Exports [plan] once in one pass and once precomposed under [visualSequences]; returns both files. */
    private class Pair2(val single: File, val multi: File, val singleRun: ExportHarness.Outcome, val multiRun: ExportHarness.Outcome)

    private fun exportBoth(p: PrecomposeHarness, plan: RenderPlan, name: String, visualSequences: Int, expectPasses: Int): Pair2 {
        val s = settings(fps = plan.canvas.fps)
        p.singlePassBudget()
        val single = p.h.export(plan, s, "${name}_single")
        assertTrue("single pass did not precompose", p.recorder.plans.isEmpty())
        p.forceVisualSequences(visualSequences)
        val pre = p.h.preflight(plan, s)
        assertTrue("preflight never refuses for sequence counts", pre.ok)
        assertTrue(pre.warnings.any { it.code == ExportWarnings.LAYERS_VS_RESOLUTION })
        val multi = p.h.export(plan, s, "${name}_multi")
        val (split, disk) = p.recorder.plans.single()
        assertEquals("$name passes", expectPasses, split.totalPasses)
        Compare.log(
            "$name: single pass ${single.wallMs} ms, precompose ${split.totalPasses} passes ${multi.wallMs} ms (emulator); " +
                "intermediate estimate ${disk.intermediateBytes} B, peak ${disk.peakBytes} B; passes ${p.recorder.events}",
        )
        val sr = single.requireResult()
        val mr = multi.requireResult()
        assertFalse("$name: intermediates deleted", p.workDir(multi.jobId).exists())
        assertEquals((1..expectPasses).flatMap { listOf("start $it/$expectPasses", "done $it/$expectPasses") }, p.recorder.events.toList())
        val fractions = multi.progress.map { it.fraction }
        assertTrue("$name progress never decreases: $fractions", fractions.zipWithNext().all { (a, b) -> b >= a })
        assertEquals(1.0, fractions.last(), 0.0)
        return Pair2(File(sr.path), File(mr.path), single, multi)
    }

    private fun assertOnGrid(out: File, fps: Int, frames: Int, name: String) {
        val pts = ExportedFile.videoPts(out)
        assertEquals("$name frame count", frames, pts.size)
        val g = FrameGrid.of(fps)
        for (k in 0 until frames) assertTrue("$name pts of frame $k: ${pts[k]}", abs(pts[k] - g.platformTimeOfFrame(k.toLong())) <= 100)
    }

    /** Frame count, SSIM, barcodes and audio of the two exports of [plan]. */
    private fun assertMatches(
        p: PrecomposeHarness,
        plan: RenderPlan,
        both: Pair2,
        name: String,
        expectedCode: ((Long) -> Long)?,
        region: FrameBarcodeRegion? = null,
    ) {
        val fps = plan.canvas.fps
        val frames = FrameGrid.ceilDiv(plan.durUs * fps, 1_000_000L).toInt()
        assertOnGrid(both.single, fps, frames, "$name single")
        assertOnGrid(both.multi, fps, frames, "$name multi")
        val cmp = Compare.frames(both.single, both.multi, frames, region)
        val worst = cmp.ssim.withIndex().minByOrNull { it.value }!!
        val mean = cmp.ssim.average()
        Compare.log("$name: SSIM precomposed vs single pass over $frames frames: min %.5f (frame %d), mean %.5f (emulator)".format(worst.value, worst.index, mean))
        val low = cmp.ssim.withIndex().filter { it.value < 0.995 }.map { "${it.index}:%.4f".format(it.value) }
        assertEquals("$name frames below SSIM 0.995", emptyList<String>(), low)
        if (expectedCode != null) {
            val wrongSingle = (0 until frames).filter { cmp.barcodesA[it]?.toLong() != expectedCode(it.toLong()) }
            val wrongMulti = (0 until frames).filter { cmp.barcodesB[it]?.toLong() != expectedCode(it.toLong()) }
            Compare.log("$name: grid-cut barcodes exact single ${frames - wrongSingle.size}/$frames, precomposed ${frames - wrongMulti.size}/$frames")
            assertEquals("$name single-pass wrong frames ${wrongSingle.map { "$it:${cmp.barcodesA[it]}" }}", emptyList<Int>(), wrongSingle)
            assertEquals("$name precomposed wrong frames ${wrongMulti.map { "$it:${cmp.barcodesB[it]}" }}", emptyList<Int>(), wrongMulti)
        }
        if (plan.audio.isNotEmpty()) {
            val a = ExportedFile.decodeAudio(p.h.ctx, both.single)
            val b = ExportedFile.decodeAudio(p.h.ctx, both.multi)
            assertEquals(48_000, b.sampleRate)
            assertEquals(2, b.channels)
            val (delta, windows) = Compare.audioDelta(a, b)
            Compare.log("$name: audio ${a.durationUs} vs ${b.durationUs} us decoded, worst 20 ms window difference %.3f dB over $windows audible windows (emulator)".format(delta))
            assertTrue("$name audible windows compared", windows >= (plan.durUs / 20_000) / 2)
            assertTrue("$name audio within QA-11's 0.5 dB: $delta", delta <= 0.5)
            assertTrue("$name audio length equal within one AAC frame", abs(a.durationUs - b.durationUs) <= 21_334)
        }
    }

    private fun matchesSinglePass(fps: Int, frames: Long) {
        val p = harness("match$fps")
        val plan = PrecomposeFixturePlans.stack(fps, frames, slots = 4)
        val both = exportBoth(p, plan, "match$fps", visualSequences = 2, expectPasses = 3)
        val src = PrecomposeFixturePlans.counter(fps).fps
        assertMatches(p, plan, both, "match$fps", { k -> PrecomposeFixturePlans.expectedBottom(plan, k, src) })
    }

    @Test
    fun precomposedMatchesSinglePassAt24fps() = matchesSinglePass(24, 48)

    @Test
    fun precomposedMatchesSinglePassAt30fps() = matchesSinglePass(30, 60)

    @Test
    fun precomposedMatchesSinglePassAt60fps() = matchesSinglePass(60, 120)

    @Test
    fun sixSlotsWithTwoVisualSequencesExportInsteadOfBeingRefused() {
        val p = harness("six")
        val plan = PrecomposeFixturePlans.stack(30, 60, slots = 6)
        val both = exportBoth(p, plan, "six", visualSequences = 2, expectPasses = 5)
        assertTrue(both.multiRun.warnings.contains(ExportWarnings.LAYERS_VS_RESOLUTION))
        assertMatches(p, plan, both, "six", { k -> PrecomposeFixturePlans.expectedBottom(plan, k, 30) })
    }

    @Test
    fun rotatedSourceMatchesSinglePass() {
        val p = harness("rotated")
        val rotated = PrecomposeFixturePlans.Source("rotated_90.mov", 30, w = 1280, h = 720, durUs = 3_000_000)
        // Displayed 720x1280: shown upright at 360x640 in the canvas centre (precomposed in pass 1).
        val plan = PrecomposeFixturePlans.stack(30, 60, slots = 3, bottom = rotated, bottomBase = PlanSize(360.0, 640.0), bottomCut = false)
        val both = exportBoth(p, plan, "rotated", visualSequences = 2, expectPasses = 2)
        assertMatches(
            p, plan, both, "rotated",
            { k -> PrecomposeFixturePlans.expectedBottom(plan, k, 30) },
            region = FrameBarcodeRegion(460, 40, 360, 640),
        )
    }

    @Test
    fun hdrSourceMatchesSinglePass() {
        val p = harness("hdr")
        val codecs = p.h.ctx.deviceProfile.codecs()
        val tone = p.h.ctx.deviceProfile.toneMapping()
        assumeTrue(
            "needs a 10-bit HEVC decoder and a tone-mapping path (GL_EXT_YUV_target or API 31+); the x86_64 emulator has no HEVC Main10 decoder (deferred to a device, AND-01 V-N5)",
            codecs.hasTenBitDecoder("video/hevc") && (tone.glYuvTarget || tone.apiLevel >= 31),
        )
        val hlg = PrecomposeFixturePlans.Source("hlg_10bit_720p.mov", 30, durUs = 3_000_000)
        val base = PrecomposeFixturePlans.stack(30, 60, slots = 3, bottom = hlg, bottomCut = false)
        val plan = base.copy(assets = base.assets + ("md_bottom" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media(hlg.name), fp = "hlg", w = 1280, h = 720, durUs = 3_000_000, transfer = com.vecvel.danaview.editor.engine.plan.PlanTransfer.HLG)))
        val both = exportBoth(p, plan, "hdr", visualSequences = 2, expectPasses = 2)
        assertMatches(p, plan, both, "hdr", { k -> PrecomposeFixturePlans.expectedBottom(plan, k, 30) })
    }

    @Test
    fun cancelDuringEachPassLeavesNoIntermediate() {
        val p = harness("cancel")
        p.forceVisualSequences(2)
        val plan = PrecomposeFixturePlans.stack(30, 120, slots = 4)
        for (pass in 1..3) {
            p.recorder.events.clear()
            p.recorder.plans.clear()
            val out = p.h.output("cancel$pass")
            val id = p.h.start(plan, settings(), out)
            val dir = p.workDir(id)
            val deadline = System.currentTimeMillis() + 300_000
            while (System.currentTimeMillis() < deadline && !p.recorder.started(pass)) Thread.sleep(20)
            assertTrue("pass $pass started", p.recorder.started(pass))
            Thread.sleep(700) // let the pass render a while
            val alive = dir.list()?.sorted().orEmpty()
            p.h.cancel(id)
            val o = p.h.await(id)
            assertEquals(EngineErrorCode.cancelled.name, o.failure?.code)
            Compare.log("cancel in pass $pass: work dir held $alive at cancel; after cancel exists=${dir.exists()}, output exists=${out.exists()}")
            if (pass > 1) assertTrue("pass $pass had its input intermediate at cancel: $alive", alive.contains("pre-${pass - 1}.mp4"))
            assertFalse("pass $pass: no intermediate left", dir.exists())
            assertFalse("pass $pass: no output left", out.exists())
            Thread.sleep(1500)
            assertFalse("pass $pass: nothing written after the cancel", dir.exists() || out.exists())
            assertTrue(p.recorder.events.none { it.startsWith("start ${pass + 1}/") })
        }
    }
}
