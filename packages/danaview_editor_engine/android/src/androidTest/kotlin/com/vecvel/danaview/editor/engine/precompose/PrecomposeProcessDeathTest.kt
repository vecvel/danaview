// OWNER: AND-19
//
// "Process death deletes intermediates" (ARCH D-45(B), §14.3; BUILD_PLAN AND-19) with a real process
// death, in two instrumentation runs (each a new process), like AND-11's ExportProcessDeathTest:
//   1. adb shell am instrument -w -e danaviewPrecomposeKillPhase start \
//        -e class com.vecvel.danaview.editor.engine.precompose.PrecomposeProcessDeathTest#startPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      starts a precomposed export (maxVisualSequences forced to 2, 4 slots → 3 passes) through
//      the production coordinator, waits until pass 2 renders (pre-1.mp4 complete on disk;
//      pre-2.mp4 may not exist yet, InAppMp4Muxer creates its file late), records the job id,
//      work dir and output in the app's files dir and returns with the export still running;
//   2. adb shell am force-stop <test package>   (kills the process mid-pass)
//   3. adb shell am instrument -w -e danaviewPrecomposeKillPhase verify \
//        -e class com.vecvel.danaview.editor.engine.precompose.PrecomposeProcessDeathTest#verifyPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      a new process opens the same roots: the launch wipe of work/ (AND-03) removed
//      work/export-<jobId>/ with every intermediate and the partial output, and the job is
//      reported interrupted once (AND-11's store).
// In a normal connected run both tests are skipped (assumption); the in-process cleanup paths
// (cancel, failure, completion) are PrecomposeExportTest's.

package com.vecvel.danaview.editor.engine.precompose

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.settings
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PrecomposeProcessDeathTest {
    private val phase: String? = InstrumentationRegistry.getArguments().getString("danaviewPrecomposeKillPhase")
    private val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val record = File(app.filesDir, "and19_process_death.json")

    @Test
    fun startPhase() {
        assumeTrue("run with -e danaviewPrecomposeKillPhase start (see the file header)", phase == "start")
        File(app.cacheDir, "and11/and19_$ROOT").deleteRecursively()
        val p = PrecomposeHarness(ROOT, fixedRoot = true)
        p.h.softwareDecoders()
        p.forceVisualSequences(2)
        val plan = PrecomposeFixturePlans.stack(30, 150, slots = 4)
        val out = p.h.output("killed")
        val id = p.h.start(plan, settings(), out)
        val dir = p.workDir(id)
        val deadline = System.currentTimeMillis() + 300_000
        while (System.currentTimeMillis() < deadline && !p.recorder.started(2)) Thread.sleep(20)
        assertTrue("pass 2 started", p.recorder.started(2))
        Thread.sleep(500)
        val alive = dir.list()?.sorted().orEmpty()
        // InAppMp4Muxer creates pre-2.mp4 late (AND-11 hand-off: 0 bytes at 50%), so only pre-1 is required.
        assertTrue("pre-1 complete while pass 2 renders: $alive", alive.contains("pre-1.mp4") && File(dir, "pre-1.mp4").length() > 0)
        assertTrue("still running", p.h.coordinator.job(id) != null)
        assertEquals(listOf(ExportJobStateKindMsg.RUNNING), p.h.activeJobs().filter { it.jobId == id }.map { it.state })
        record.writeText(JSONObject().put("jobId", id).put("workDir", dir.absolutePath).put("output", out.absolutePath).toString())
        Compare.log("precompose process-death start phase: job $id in pass 2, work dir holds $alive; kill the process now")
        // No close(): the export keeps running until the process dies.
    }

    @Test
    fun verifyPhase() {
        assumeTrue("run with -e danaviewPrecomposeKillPhase verify after the start phase and am force-stop", phase == "verify")
        val doc = JSONObject(record.readText())
        val id = doc.getString("jobId")
        val dir = File(doc.getString("workDir"))
        val out = File(doc.getString("output"))
        val h = ExportHarness("and19_$ROOT", fixedRoot = true)
        try {
            assertFalse("the launch wipe removed the intermediates", dir.exists())
            assertFalse("the launch wipe removed the partial output", out.exists())
            assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), h.activeJobs().filter { it.jobId == id }.map { it.state })
            h.consume(id)
            assertEquals(0, h.activeJobs().count { it.jobId == id })
            Compare.log("precompose process-death verify phase: job $id reported interrupted once; work dir and partial output wiped")
        } finally {
            h.close()
            record.delete()
        }
    }

    companion object {
        private const val ROOT = "process_death"
    }
}
