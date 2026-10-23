// OWNER: HOM-30A
//
// Placeholder created by HOM-25: the Android visual signature tool (HOM-30A, on the HOM-27 route,
// PdfBox-Android). Until HOM-30A lands nothing is offered (capabilities.tools) and requests answer
// notSupportedOnDevice (glue/PdfToolsHostApiImpl.kt).

package com.vecvel.danaview.pdf.sign

import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg

object PdfSigner {
    /** The ticket that implements it. */
    const val OWNER = "HOM-30A"

    /** The tools of this class that have landed on Android. */
    val supported: List<PdfToolKindMsg> = emptyList()
}
