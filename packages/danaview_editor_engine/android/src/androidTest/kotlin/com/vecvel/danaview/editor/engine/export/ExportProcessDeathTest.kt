// OWNER: AND-11
//
// "Interrupted after process kill" (ARCH §14.1 step 7, D-22; BUILD_PLAN AND-11) with a real process
// death, in two instrumentation runs (each a new process):
//   1. adb shell am instrument -w -e danaviewExportKillPhase start \
//        -e class com.vecvel.danaview.editor.engine.export.ExportProcessDeathTest#startPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      starts a long export through the production coordinator, waits until it renders, records the
//      job id and output path in the app's files dir and returns with the export still running;
//   2. adb shell am force-stop <test package>   (kills the process mid-export if the runner has not)
//   3. adb shell am instrument -w -e danaviewExportKillPhase verify \
//        -e class com.vecvel.danaview.editor.engine.export.ExportProcessDeathTest#verifyPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      a new process opens the same roots: the launch wipe removed the partial output, activeJobs
//      reports the job `interrupted` (one-shot) until consumeJobRecord, then never again.
// In a normal connected run both tests are skipped (assumption); ExportConformanceTest
// .aRecordOfADeadProcessIsReportedInterruptedOnce covers the same store rule in-process.

package com.vecvel.danaview.editor.engine.export

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ExportProcessDeathTest {
    private val phase: String? = InstrumentationRegistry.getArguments().getString("danaviewExportKillPhase")
    private val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val record = File(app.filesDir, "and11_process_death.json")

    @Test
    fun startPhase() {
        assumeTrue("run with -e danaviewExportKillPhase start (see the file header)", phase == "start")
        File(app.cacheDir, "and11/$ROOT").deleteRecursively()
        val h = ExportHarness(ROOT, fixedRoot = true)
        val g = FrameGrid.of(30)
        val frames = 240L
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1920, 1080, 30), durUs = g.timeOfFrame(frames),
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_1080p30.mp4"), fp = "fc1080", w = 1920, h = 1080, durUs = 8_000_000)),
            layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, frames, 0, 30, base = PlanSize(1920.0, 1080.0))),
            audio = emptyList(),
        )
        val out = h.output("killed")
        val id = h.start(plan, settings(w = 1920, h = 1080), out)
        val deadline = System.currentTimeMillis() + 120_000
        while (System.currentTimeMillis() < deadline && h.progress(id).none { it.phase == ExportPhaseMsg.RENDERING && it.fraction > 0.05 }) Thread.sleep(20)
        val p = h.progress(id).last()
        assertEquals(ExportPhaseMsg.RENDERING, p.phase)
        assertTrue("still running", h.coordinator.job(id) != null)
        assertEquals(listOf(ExportJobStateKindMsg.RUNNING), h.activeJobs().filter { it.jobId == id }.map { it.state })
        record.writeText(JSONObject().put("jobId", id).put("output", out.absolutePath).toString())
        Log.i(EXPORT_TEST_TAG, "process-death start phase: job $id running at ${(p.fraction * 100).toInt()}%, partial output ${out.length()} bytes; kill the process now")
        // No close(): the export keeps running until the process dies.
    }

    @Test
    fun verifyPhase() {
        assumeTrue("run with -e danaviewExportKillPhase verify after the start phase and am force-stop", phase == "verify")
        val doc = JSONObject(record.readText())
        val id = doc.getString("jobId")
        val out = File(doc.getString("output"))
        val h = ExportHarness(ROOT, fixedRoot = true)
        try {
            assertFalse("the launch wipe removed the partial output", out.exists())
            val first = h.activeJobs().filter { it.jobId == id }
            assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), first.map { it.state })
            assertEquals("reported until consumed", 1, h.activeJobs().count { it.jobId == id })
            h.consume(id)
            assertEquals("one-shot", 0, h.activeJobs().count { it.jobId == id })
            Log.i(EXPORT_TEST_TAG, "process-death verify phase: job $id reported interrupted once in the new process, partial output wiped")
        } finally {
            h.close()
            record.delete()
        }
    }

    companion object {
        private const val ROOT = "process_death"
    }
}
