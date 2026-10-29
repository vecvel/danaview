// OWNER: HOM-28A
//
// The page tools behind PdfToolsHostApi (merge, split, reorder, rotate, deletePages) and the HOM-28
// amendment's PdfOrganiseHostApi (pigeons/pdf_api.dart) on Android: turns each Pigeon request into
// a call of the Flutter-free core (tools/PdfPageToolsCore.kt, PdfBox-Android). The glue
// (glue/PdfToolsHostApiImpl.kt) runs these on the tools thread with the job's cancel flag and
// progress, and answers on the main thread. As on Apple (darwin/Classes/Tools/PdfPageTools.swift).

package com.vecvel.danaview.pdf.tools

import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfDeletePagesRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfMergeRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfOrganiseRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfReorderRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfRotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSplitRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg

object PdfPageTools {
    /** The ticket that implements it. */
    const val OWNER = "HOM-28A"

    /**
     * The tools of this class that work here (PdfCapabilitiesMsg.tools). reorder + rotate +
     * deletePages together also advertise PdfOrganiseHostApi (Dart `canOrganise`).
     */
    val supported: List<PdfToolKindMsg> = listOf(
        PdfToolKindMsg.MERGE,
        PdfToolKindMsg.SPLIT,
        PdfToolKindMsg.REORDER,
        PdfToolKindMsg.ROTATE,
        PdfToolKindMsg.DELETE_PAGES,
    )

    fun source(m: PdfToolInputMsg) = PdfToolSource(m.path, m.password, m.isImage)

    fun int(value: Long): Int {
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) throw PdfFailure.invalid("number out of range")
        return value.toInt()
    }

    fun merge(request: PdfMergeRequestMsg, control: PdfToolControl): List<PdfWrittenFile> =
        listOf(PdfPageToolsCore.merge(request.inputs.map(::source), request.outPath, control))

    fun split(request: PdfSplitRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        val ranges = request.ranges.map {
            val start = int(it.start)
            val end = int(it.end)
            if (start >= end) throw PdfFailure.invalid("empty range")
            start until end
        }
        return PdfPageToolsCore.split(source(request.input), ranges, request.outPaths, control)
    }

    fun reorder(request: PdfReorderRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        val order = request.order.map(::int)
        return listOf(PdfPageToolsCore.organise(source(request.input), request.outPath, control) { PdfPageToolsCore.reorderPlan(order, it) })
    }

    fun rotate(request: PdfRotateRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        val pages = request.pages.map(::int)
        val degrees = int(request.degrees)
        return listOf(PdfPageToolsCore.organise(source(request.input), request.outPath, control) { PdfPageToolsCore.rotatePlan(pages, degrees, it) })
    }

    fun deletePages(request: PdfDeletePagesRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        val pages = request.pages.map(::int)
        return listOf(PdfPageToolsCore.organise(source(request.input), request.outPath, control) { PdfPageToolsCore.deletePlan(pages, it) })
    }

    fun organise(request: PdfOrganiseRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        val plan = request.pages.map { PdfPagePlanItem(int(it.sourcePage), int(it.rotation)) }
        return listOf(PdfPageToolsCore.organise(source(request.input), plan, request.outPath, control))
    }
}
