// OWNER: AND-18
//
// "Process death leaves no partial file" (BUILD_PLAN AND-18) with a real process death, in two
// instrumentation runs (each a new process), like AND-11's ExportProcessDeathTest:
//   1. adb shell am instrument -w -e danaviewRenderKillPhase start \
//        -e class com.vecvel.danaview.editor.engine.render.RenderProcessDeathTest#startPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      starts a long render through the production service, waits until it renders (its part file
//      exists), records the paths in the app's files dir and returns with the render running;
//   2. adb shell am force-stop <test package>   (kills the process mid-render)
//   3. adb shell am instrument -w -e danaviewRenderKillPhase verify \
//        -e class com.vecvel.danaview.editor.engine.render.RenderProcessDeathTest#verifyPhase <test package>/androidx.test.runner.AndroidJUnitRunner
//      a new process opens the same roots: the first use of the render-preview services removes
//      the dead render's part file; the output never appeared, so CORE-37's index (written only
//      from a job's done event) never names it.
// In a normal connected run both tests are skipped (assumption); cancel and pre-emption cleanup
// run in-process in RenderPreviewJobTest.

package com.vecvel.danaview.editor.engine.render

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewServices
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class RenderProcessDeathTest {
    private val phase: String? = InstrumentationRegistry.getArguments().getString("danaviewRenderKillPhase")
    private val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val record = File(app.filesDir, "and18_process_death.json")

    @Test
    fun startPhase() {
        assumeTrue("run with -e danaviewRenderKillPhase start (see the file header)", phase == "start")
        val engine = FreezeEngine(ROOT)
        val rig = RenderRig(engine)
        val out = rig.output("killed")
        val part = RenderPreviewSpecs.partFile(out)
        val id = rig.start(RangeCut.cut(FallbackPlans.gridCut(60), 0, 240), out)
        val deadline = System.currentTimeMillis() + 120_000
        while (System.currentTimeMillis() < deadline && !part.exists()) Thread.sleep(20)
        assertTrue("the render writes its part file", part.exists())
        assertFalse("not finished", out.exists())
        record.writeText(
            JSONObject().put("jobId", id).put("cache", engine.paths.cacheRoot.absolutePath).put("support", engine.paths.supportRoot.absolutePath)
                .put("output", out.absolutePath).put("part", part.absolutePath).toString(),
        )
        log18("render process-death start phase: job $id renders (part file ${part.length()} bytes); kill the process now")
        // No close(): the render keeps running until the process dies.
    }

    @Test
    fun verifyPhase() {
        assumeTrue("run with -e danaviewRenderKillPhase verify after the start phase and am force-stop", phase == "verify")
        val doc = JSONObject(record.readText())
        val out = File(doc.getString("output"))
        val part = File(doc.getString("part"))
        assertTrue("the dead render left its part file", part.exists())
        val ctx = EngineContext(app, EngineThreads.android())
        try {
            ctx.installRoots(Paths.fromDart(doc.getString("cache"), doc.getString("support")))
            // First use of the services in this process (the editor opening a session or asking the power state).
            RenderPreviewServices.of(ctx)
            val deadline = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < deadline && part.exists()) Thread.sleep(20)
            val left = part.parentFile?.list()?.sorted().orEmpty()
            log18("render process-death verify phase: renders dir now $left")
            assertFalse("the part file is gone", part.exists())
            assertFalse("no output was ever completed", out.exists())
            assertEquals("no partial file in the renders directory", emptyList<String>(), left.filter { it.endsWith(RenderPreviewSpecs.PART_SUFFIX) })
            record.delete()
        } finally {
            ctx.threads.shutdown()
        }
    }

    private companion object {
        const val ROOT = "and18_death"
    }
}
