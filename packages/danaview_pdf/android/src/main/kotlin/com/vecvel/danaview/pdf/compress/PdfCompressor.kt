// OWNER: HOM-31A
//
// Placeholder created by HOM-25: the Android compress tool (HOM-31A, on the HOM-27 route,
// PdfBox-Android). Until HOM-31A lands nothing is offered (capabilities.tools) and requests answer
// notSupportedOnDevice (glue/PdfToolsHostApiImpl.kt).

package com.vecvel.danaview.pdf.compress

import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg

object PdfCompressor {
    /** The ticket that implements it. */
    const val OWNER = "HOM-31A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = emptyList()
}
