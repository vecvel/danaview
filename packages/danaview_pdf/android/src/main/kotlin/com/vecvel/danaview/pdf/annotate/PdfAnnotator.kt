// OWNER: HOM-29A
//
// The Android annotate tool (HOM-29A, on PdfBox-Android per HOM-27; as darwin/Classes/Annotate/
// PdfAnnotator.swift): turns the Pigeon messages of `PdfToolsHostApi.annotate` (frozen) and of the
// HOM-29 amendment's `PdfAnnotateHostApi.save` into calls of the Flutter-free core
// (annotate/PdfAnnotateCore.kt), and the annotate session's items into the texture view's preview.
// The glue (glue/PdfToolsHostApiImpl.kt, annotate/PdfAnnotateHostApiImpl.kt) runs saves as tool
// jobs (`tool: annotate`) on the tools pool with the job's cancel flag and progress.
//
// `annotate` is reported in capabilities().tools: the save and the texture view's annotate mode
// both work (the preview natively, the touches through the Dart texture view,
// lib/src/pdf_texture_annotate.dart).

package com.vecvel.danaview.pdf.annotate

import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateSaveRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotationMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignatureStampMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.tools.PdfPageTools
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfWrittenFile
import com.vecvel.danaview.pdf.viewer.PreviewItem

object PdfAnnotator {
    /** The ticket that implements it. */
    const val OWNER = "HOM-29A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = listOf(PdfToolKindMsg.ANNOTATE)

    fun box(r: PdfRectMsg) = PdfBox(r.x, r.y, r.width, r.height)

    fun spec(m: PdfAnnotationMsg) = PdfAnnotationSpec(
        kind = PdfAnnotationKind.entries[m.kind.raw],
        pageIndex = PdfPageTools.int(m.pageIndex),
        rects = m.rects.map(::box),
        strokes = m.strokes.map { it.points.toDoubleArray() },
        colorArgb = m.colorArgb and 0xFFFFFFFFL,
        lineWidth = m.lineWidth,
        text = m.text,
    )

    fun stamp(m: PdfSignatureStampMsg) = PdfStampSpec(PdfPageTools.int(m.pageIndex), box(m.rect), m.imagePath, m.rotationDegrees)

    /** A session item for the preview; `invalidArgument` unless exactly one of annotation and stamp is set. */
    fun item(m: PdfAnnotateItemMsg): PreviewItem {
        if ((m.annotation == null) == (m.stamp == null)) throw PdfFailure.invalid("item needs one annotation or stamp")
        return PreviewItem(m.id, m.annotation?.let(::spec), m.stamp?.let(::stamp))
    }

    /** The frozen `PdfToolsHostApi.annotate`: the save without stamps and burn-in. */
    fun annotate(request: PdfAnnotateRequestMsg, control: PdfToolControl): List<PdfWrittenFile> =
        listOf(PdfAnnotateCore.annotate(PdfPageTools.source(request.input), request.annotations.map(::spec), emptyList(), false, request.outPath, control))

    /** `PdfAnnotateHostApi.save` (HOM-29 amendment). */
    fun save(request: PdfAnnotateSaveRequestMsg, control: PdfToolControl): List<PdfWrittenFile> = listOf(
        PdfAnnotateCore.annotate(
            PdfPageTools.source(request.input),
            request.annotations.map(::spec),
            request.stamps.map(::stamp),
            request.burnIn,
            request.outPath,
            control,
        ),
    )
}
