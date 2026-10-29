// OWNER: HOM-30A
//
// The Android visual signature tool (HOM-30A, on PdfBox-Android per HOM-27; as darwin/Classes/Sign/
// PdfSigner.swift): the frozen `PdfToolsHostApi.sign(PdfSignRequestMsg)` routes to the HOM-29A
// annotate save with the request's image stamps and `burnIn: true` (annotate/PdfAnnotateCore.kt):
// each signature image is drawn into its page's content (PNG alpha kept; turned clockwise around its
// rect's centre, a quarter turn filling the rect), no Stamp annotation is left, the page's own
// annotations, boxes and /Rotate stay, text stays text, encrypted in -> encrypted out, a file that
// forbids changes answers `unsupported`. Empty stamps -> `invalidArgument`. The Dart sign mode saves
// through `PdfAnnotateHostApi.save(stamps, burnIn: true)` itself; both are tool jobs on the glue's
// registry (glue/PdfToolsHostApiImpl.kt), progress `tool: sign` here.
//
// `sign` is reported in capabilities().tools: the burn-in save works and the texture view's `place`
// input does (the selected stamp's handle natively, viewer/PdfAnnotatePreview.kt; the drag in the
// Dart texture view, lib/src/pdf_texture_annotate.dart).

package com.vecvel.danaview.pdf.sign

import com.vecvel.danaview.pdf.annotate.PdfAnnotateCore
import com.vecvel.danaview.pdf.annotate.PdfAnnotator
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfSignRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.tools.PdfPageTools
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfWrittenFile

object PdfSigner {
    /** The ticket that implements it. */
    const val OWNER = "HOM-30A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = listOf(PdfToolKindMsg.SIGN)

    /** The frozen sign: the annotate save with [PdfSignRequestMsg.stamps] burned in. */
    fun sign(request: PdfSignRequestMsg, control: PdfToolControl): List<PdfWrittenFile> {
        if (request.stamps.isEmpty()) throw PdfFailure.invalid("no signatures")
        return listOf(
            PdfAnnotateCore.annotate(
                PdfPageTools.source(request.input),
                emptyList(),
                request.stamps.map(PdfAnnotator::stamp),
                burnIn = true,
                outPath = request.outPath,
                control = control,
            ),
        )
    }
}
