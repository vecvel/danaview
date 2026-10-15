// OWNER: AND-18
//
// The render-preview job through the production service and AND-05's registry on the emulator
// (ARCH D-45 (A), §12.3 `renderPreview`; BUILD_PLAN AND-18):
// - refusals before a job exists (non-preview plan, held layer, a render file as input);
// - progress ≤ 4 Hz and never backwards, done with the asset (path, size, range duration), the
//   file renamed from its part file only when complete;
// - cancel while rendering ends `cancelled` and leaves neither the part file nor the output;
// - an export pre-empts a running render (part file deleted, re-queued, restarted after the
//   export) and none starts while an export runs;
// - thermal SEVERE pauses the render (part file deleted) until the status drops, then it restarts
//   and completes.
// Process death is RenderProcessDeathTest's. Emulator numbers, logged under AND18.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobRegistry
import com.vecvel.danaview.editor.engine.core.ThermalLevels
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewJobService
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class RenderPreviewJobTest {
    private val engines = ArrayList<FreezeEngine>()

    private fun rig(name: String): RenderRig = RenderRig(FreezeEngine(name).also { engines += it })

    @After
    fun tearDown() {
        engines.forEach { it.close() }
    }

    /** A long render: AND-01's grid cut over 4 s at 60 fps (240 frames from three 720p60 sources). */
    private fun longRange(): RenderPlan = RangeCut.cut(FallbackPlans.gridCut(60), 0, 240)

    private fun waitFor(what: String, timeoutMs: Long = 120_000, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (cond()) return
            Thread.sleep(20)
        }
        throw AssertionError("timed out waiting for: $what")
    }

    /** Whether job [id] reported progress above [min] (the muxer may create its file late). */
    private fun progressed(r: RenderRig, id: String, min: Double = 0.05): Boolean =
        r.events(id).any { it.kind == EngineEventKindMsg.PROGRESS && (it.progress ?: 0.0) > min }

    private fun startCode(r: RenderRig, plan: RenderPlan, out: File): String? = try {
        r.start(plan, out)
        null
    } catch (e: EngineException) {
        e.code.name
    }

    @Test
    fun badRangePlansAreRefusedBeforeAJobExists() {
        val r = rig("and18_refuse")
        val plan = RangeCut.cut(FallbackPlans.gridCut(30), 31, 43)
        val out = r.output("refused")
        assertEquals("planInvalid", startCode(r, plan.copy(target = PlanTarget.EXPORT), out))
        val held = plan.copy(layers = plan.layers.mapIndexed { i, l -> if (i == 0) l.copy(hold = true) else l })
        assertEquals("planInvalid", startCode(r, held, out))
        val renderInput = File(r.rendersDir, "earlier.mp4")
        val reads = plan.copy(assets = plan.assets + ("r" to PlanAsset(PlanAssetKind.VIDEO, "file://" + renderInput.absolutePath, fp = "r", w = 640, h = 360)))
        assertEquals("planInvalid", startCode(r, reads, out))
        assertEquals("no job was registered", 0, r.engine.ctx.jobs.jobCount)
        assertFalse(out.exists())
    }

    @Test
    fun aRenderReportsProgressAndEndsWithItsAsset() {
        val r = rig("and18_progress")
        val plan = RangeCut.cut(FallbackPlans.gridCut(30), 31, 92)
        val out = r.output("progress")
        val t0 = System.nanoTime()
        val id = r.start(plan, out)
        val end = r.engine.awaitTerminal(id, 300_000)
        val secs = (System.nanoTime() - t0) / 1e9
        assertEquals("${end.failure?.code}", EngineEventKindMsg.JOB_DONE, end.kind)
        val progress = r.events(id).filter { it.kind == EngineEventKindMsg.PROGRESS }.map { it.progress!! }
        val asset = end.jobDone!!.asset!!
        log18("render job (emulator): ${progress.size} progress events in %.1f s (%s), asset %d bytes, %d µs".format(secs, progress.map { "%.2f".format(it) }, asset.sizeBytes, asset.durationUs))
        assertEquals(com.vecvel.danaview.editor.engine.pigeon.JobKindMsg.RENDER_PREVIEW, end.jobDone!!.kind)
        assertEquals(out.absolutePath, asset.path)
        assertEquals(out.length(), asset.sizeBytes)
        assertEquals("the range's duration", plan.durUs, asset.durationUs)
        assertTrue("progress reported", progress.isNotEmpty())
        assertTrue("progress never moves backwards: $progress", progress.zipWithNext().all { (a, b) -> b >= a })
        assertTrue("progress in 0..1", progress.all { it in 0.0..1.0 })
        assertTrue("<= 4 Hz: ${progress.size} events in $secs s", progress.size <= secs * 4 + 2)
        assertFalse(RenderPreviewSpecs.partFile(out).exists())
    }

    @Test
    fun cancelWhileRenderingLeavesNoPartialFile() {
        val r = rig("and18_cancel")
        val out = r.output("cancelled")
        val part = RenderPreviewSpecs.partFile(out)
        val id = r.start(longRange(), out)
        // InAppMp4Muxer creates its file late (about half way): cancel once it exists.
        waitFor("the render writes its part file") { part.exists() }
        val partBytes = part.length()
        r.engine.ctx.jobs.cancel(id)
        val end = r.engine.awaitTerminal(id, 60_000)
        Thread.sleep(1_500)
        log18("cancel (emulator): part file existed ($partBytes bytes); after cancel part=${part.exists()} output=${out.exists()}")
        assertEquals(EngineEventKindMsg.FAILURE, end.kind)
        assertEquals("cancelled", end.failure!!.code)
        assertFalse("no part file after cancel", part.exists())
        assertFalse("no output after cancel", out.exists())
        assertEquals(emptyList<File>(), RenderPreviewSpecs.staleParts(r.rendersDir))
    }

    @Test
    fun anExportPausesRendersAndNoneStartsWhileItRuns() {
        val r = rig("and18_export")
        val jobs = r.engine.ctx.jobs
        val out = r.output("paused")
        val part = RenderPreviewSpecs.partFile(out)
        // A running render is stopped by an export, its part file deleted, and it waits.
        val id = r.start(longRange(), out, JobPriorityMsg.NORMAL)
        waitFor("the render runs") { progressed(r, id) }
        jobs.setExportActive("ex_and18", true)
        waitFor("the render is re-queued") { jobs.state(id) == JobRegistry.State.QUEUED }
        Thread.sleep(1_000)
        assertEquals("still queued while the export runs", JobRegistry.State.QUEUED, jobs.state(id))
        assertFalse("its part file is gone", part.exists())
        val restarts = jobs.restarts(id)
        // A render started during the export does not start either.
        val out2 = r.output("queued")
        val id2 = r.start(RangeCut.cut(FallbackPlans.gridCut(30), 31, 43), out2)
        Thread.sleep(1_500)
        assertEquals(JobRegistry.State.QUEUED, jobs.state(id2))
        assertFalse(RenderPreviewSpecs.partFile(out2).exists())
        jobs.setExportActive("ex_and18", false)
        val end = r.engine.awaitTerminal(id, 600_000)
        val end2 = r.engine.awaitTerminal(id2, 300_000)
        log18("export pre-emption (emulator): render restarted $restarts time(s) after the export; outcomes ${end.kind} / ${end2.kind}")
        assertEquals(1, restarts)
        assertEquals("${end.failure?.code}", EngineEventKindMsg.JOB_DONE, end.kind)
        assertEquals("${end2.failure?.code}", EngineEventKindMsg.JOB_DONE, end2.kind)
        assertTrue(out.exists() && out2.exists())
    }

    @Test
    fun thermalSeverePausesTheRenderUntilTheDeviceCools() {
        val r = rig("and18_thermal")
        val heat = AtomicInteger(ThermalLevels.STATUS_NONE)
        val log = CopyOnWriteArrayList<String>()
        r.service.thermalStatus = { heat.get() }
        r.service.thermalPollMs = 100
        r.service.observer = object : RenderPreviewJobService.Observer {
            override fun onRunStarted(jobId: String, attempt: Int) {
                log += "start $attempt"
            }

            override fun onThermalPause(jobId: String) {
                log += "pause"
            }

            override fun onCompleted(jobId: String, frames: Int) {
                log += "done $frames"
            }
        }
        val out = r.output("thermal")
        val part = RenderPreviewSpecs.partFile(out)
        val id = r.start(longRange(), out)
        waitFor("the render runs") { progressed(r, id) }
        heat.set(ThermalLevels.STATUS_SEVERE)
        waitFor("the render pauses") { "pause" in log }
        Thread.sleep(800)
        assertFalse("the part file is deleted while paused", part.exists())
        assertEquals("it waits (no restart while hot)", 1, log.count { it.startsWith("start") })
        assertEquals("the job is still running (waiting)", JobRegistry.State.RUNNING, r.engine.ctx.jobs.state(id))
        heat.set(ThermalLevels.STATUS_MODERATE)
        val end = r.engine.awaitTerminal(id, 300_000)
        log18("thermal pause (emulator): $log")
        assertEquals("${end.failure?.code}", EngineEventKindMsg.JOB_DONE, end.kind)
        assertEquals(listOf("start 0", "pause", "start 1"), log.take(3))
        assertNotNull(log.firstOrNull { it.startsWith("done") })
        assertTrue(out.exists())
    }
}
