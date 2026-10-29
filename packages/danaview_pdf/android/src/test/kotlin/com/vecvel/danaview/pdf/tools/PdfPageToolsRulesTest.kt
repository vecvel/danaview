// OWNER: HOM-28A
//
// JVM tests of the page tools' pure rules (tools/PdfPageToolsCore.kt, tools/PdfPageTools.kt,
// glue/PdfJobs.kt): the plans of reorder / rotate / delete / organise, rotation arithmetic, the
// output-path checks, request validation before any file is touched, the job registry (ids, cancel,
// progress events) and the capabilities. PdfBox itself runs in the instrumented PdfPageToolsTest.

package com.vecvel.danaview.pdf.tools

import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfJobRegistry
import com.vecvel.danaview.pdf.pigeon.PdfPageRangeMsg
import com.vecvel.danaview.pdf.pigeon.PdfSplitRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolProgressMsg
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class PdfPageToolsRulesTest {
    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("hom28a").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun code(block: () -> Unit): PdfErrorCode {
        try {
            block()
        } catch (f: PdfFailure) {
            return f.code
        }
        fail("expected a PdfFailure")
        error("unreachable")
    }

    private val never = object : PdfToolControl {
        override val isCancelled = false
        override fun progress(done: Int, total: Int) = Unit
    }

    // ---- plans ----

    @Test
    fun reorderPlanIsAPermutation() {
        assertEquals(listOf(2, 0, 1), PdfPageToolsCore.reorderPlan(listOf(2, 0, 1), 3).map { it.sourcePage })
        assertTrue(PdfPageToolsCore.reorderPlan(listOf(2, 0, 1), 3).all { it.rotation == 0 })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.reorderPlan(listOf(0, 1), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.reorderPlan(listOf(0, 0, 1), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.reorderPlan(listOf(0, 1, 3), 3) })
    }

    @Test
    fun rotatePlanTurnsOnlyTheListedPages() {
        val plan = PdfPageToolsCore.rotatePlan(listOf(0, 2, 2), -90, 4)
        assertEquals(listOf(0, 1, 2, 3), plan.map { it.sourcePage })
        assertEquals(listOf(-90, 0, -90, 0), plan.map { it.rotation })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.rotatePlan(listOf(0), 45, 4) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.rotatePlan(emptyList(), 90, 4) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.rotatePlan(listOf(4), 90, 4) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.rotatePlan(listOf(-1), 90, 4) })
    }

    @Test
    fun deletePlanKeepsAtLeastOnePage() {
        assertEquals(listOf(0, 2), PdfPageToolsCore.deletePlan(listOf(1, 3), 4).map { it.sourcePage })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.deletePlan(listOf(0, 1, 2), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.deletePlan(emptyList(), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.deletePlan(listOf(3), 3) })
    }

    @Test
    fun organisePlansAreChecked() {
        PdfPageToolsCore.checkPlan(listOf(PdfPagePlanItem(2, 90), PdfPagePlanItem(0, -270)), 3)
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkPlan(emptyList(), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkPlan(listOf(PdfPagePlanItem(1), PdfPagePlanItem(1)), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkPlan(listOf(PdfPagePlanItem(3)), 3) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkPlan(listOf(PdfPagePlanItem(0, 30)), 3) })
    }

    @Test
    fun rotationsNormaliseToRightAngles() {
        assertEquals(0, PdfPageToolsCore.normalizedRotation(360))
        assertEquals(270, PdfPageToolsCore.normalizedRotation(-90))
        assertEquals(180, PdfPageToolsCore.normalizedRotation(90 + 90))
        assertEquals(90, PdfPageToolsCore.normalizedRotation(-630))
        assertEquals(0, PdfPageToolsCore.normalizedRotation(0))
    }

    // ---- output paths ----

    @Test
    fun outputsMustBeNewFilesInExistingFolders() {
        val input = File(dir, "in.pdf").apply { writeText("x") }
        PdfPageToolsCore.checkNewFile(File(dir, "out.pdf").path, listOf(input.path))
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkNewFile("", listOf(input.path)) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkNewFile(input.path, listOf(input.path)) })
        // The same file through another spelling is still the input.
        val other = File(dir, "./sub/../in.pdf").path
        File(dir, "sub").mkdirs()
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkNewFile(other, listOf(input.path)) })
        val existing = File(dir, "exists.pdf").apply { writeText("keep") }
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageToolsCore.checkNewFile(existing.path, listOf(input.path)) })
        assertEquals("keep", existing.readText())
        assertEquals(PdfErrorCode.notFound, code { PdfPageToolsCore.checkNewFile(File(dir, "missing/out.pdf").path, listOf(input.path)) })
    }

    @Test
    fun badRequestsFailBeforeAnyFileIsTouched() {
        val input = File(dir, "in.pdf").apply { writeText("not opened") }
        val out = File(dir, "out.pdf")
        // Merge needs two inputs.
        assertEquals(
            PdfErrorCode.invalidArgument,
            code { PdfPageToolsCore.merge(listOf(PdfToolSource(input.path)), out.path, never) },
        )
        // Split: an empty or reversed range, one output per range, distinct outputs, PDFs only.
        fun split(ranges: List<PdfPageRangeMsg>, outs: List<String>, image: Boolean = false) =
            PdfPageTools.split(PdfSplitRequestMsg("j", PdfToolInputMsg(input.path, null, image), ranges, outs), never)
        assertEquals(PdfErrorCode.invalidArgument, code { split(listOf(PdfPageRangeMsg(2, 2)), listOf(out.path)) })
        assertEquals(PdfErrorCode.invalidArgument, code { split(listOf(PdfPageRangeMsg(3, 1)), listOf(out.path)) })
        assertEquals(PdfErrorCode.invalidArgument, code { split(listOf(PdfPageRangeMsg(0, 1)), listOf(out.path, File(dir, "b.pdf").path)) })
        assertEquals(PdfErrorCode.invalidArgument, code { split(listOf(PdfPageRangeMsg(0, 1), PdfPageRangeMsg(1, 2)), listOf(out.path, out.path)) })
        assertEquals(PdfErrorCode.invalidArgument, code { split(listOf(PdfPageRangeMsg(0, 1)), listOf(out.path), image = true) })
        // Organise needs a PDF.
        assertEquals(
            PdfErrorCode.invalidArgument,
            code { PdfPageToolsCore.organise(PdfToolSource(input.path, isImage = true), listOf(PdfPagePlanItem(0)), out.path, never) },
        )
        // Numbers outside Int.
        assertEquals(PdfErrorCode.invalidArgument, code { PdfPageTools.int(Long.MAX_VALUE) })
        assertFalse(out.exists())
        assertEquals("not opened", input.readText())
    }

    // ---- jobs ----

    @Test
    fun jobsReportProgressAndCancel() {
        val events = ArrayList<PdfToolProgressMsg>()
        val jobs = PdfJobRegistry { events += it }
        val job = jobs.start("a", PdfToolKindMsg.REORDER)
        assertEquals(PdfErrorCode.invalidArgument, code { jobs.start("a", PdfToolKindMsg.MERGE) })
        assertEquals(PdfErrorCode.invalidArgument, code { jobs.start("", PdfToolKindMsg.MERGE) })
        job.progress(0, 4)
        job.progress(1, 4)
        job.progress(4, 4)
        job.progress(0, 0)
        assertEquals(listOf(0.0, 0.25, 1.0, 0.0), events.map { it.fraction })
        assertEquals(listOf(0L, 1L, 4L, 0L), events.map { it.pagesDone })
        assertTrue(events.all { it.jobId == "a" && it.tool == PdfToolKindMsg.REORDER })
        assertFalse(job.isCancelled)
        jobs.cancel("other")
        assertFalse(job.isCancelled)
        jobs.cancel("a")
        assertTrue(job.isCancelled)
        assertEquals(PdfErrorCode.cancelled, code { PdfPageToolsCore.checkCancelled(job) })
        assertEquals(1, jobs.runningCount)
        jobs.finish(job)
        assertEquals(0, jobs.runningCount)
        // The id is free again.
        jobs.finish(jobs.start("a", PdfToolKindMsg.SPLIT))
    }

    @Test
    fun capabilitiesListThePageTools() {
        assertEquals(
            setOf(PdfToolKindMsg.MERGE, PdfToolKindMsg.SPLIT, PdfToolKindMsg.REORDER, PdfToolKindMsg.ROTATE, PdfToolKindMsg.DELETE_PAGES),
            PdfPageTools.supported.toSet(),
        )
        assertEquals("HOM-28A", PdfPageTools.OWNER)
    }
}
