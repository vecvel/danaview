// OWNER: HOM-28A
//
// Placeholder created by HOM-25: the Android page tools (merge, split, reorder, rotate, delete) (HOM-28A, on the HOM-27 route,
// PdfBox-Android). Until HOM-28A lands nothing is offered (capabilities.tools) and requests answer
// notSupportedOnDevice (glue/PdfToolsHostApiImpl.kt).

package com.vecvel.danaview.pdf.tools

import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg

object PdfPageTools {
    /** The ticket that implements it. */
    const val OWNER = "HOM-28A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = emptyList()
}
