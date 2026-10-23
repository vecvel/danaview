// OWNER: HOM-29A
//
// Placeholder created by HOM-25: the Android annotate and highlight tool (HOM-29A, on the HOM-27 route,
// PdfBox-Android). Until HOM-29A lands nothing is offered (capabilities.tools) and requests answer
// notSupportedOnDevice (glue/PdfToolsHostApiImpl.kt).

package com.vecvel.danaview.pdf.annotate

import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg

object PdfAnnotator {
    /** The ticket that implements it. */
    const val OWNER = "HOM-29A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = emptyList()
}
