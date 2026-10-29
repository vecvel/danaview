// OWNER: HOM-25
//
// PdfToolsHostApi on Android: routes each tool to the class of its ticket - tools/PdfPageTools
// (HOM-28A: merge, split, reorder, rotate, delete), annotate/PdfAnnotator (HOM-29A), sign/PdfSigner
// (HOM-30A), compress/PdfCompressor (HOM-31A, landed: [compressor]). Until the others land they
// answer notSupportedOnDevice. The write engine is PdfBox-Android (HOM-27); HOM-25 itself never
// writes a PDF.

package com.vecvel.danaview.pdf.glue

import com.vecvel.danaview.pdf.annotate.PdfAnnotator
import com.vecvel.danaview.pdf.compress.PdfCompressor
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfDeletePagesRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfMergeRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfReorderRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfRotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSplitRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolsHostApi
import com.vecvel.danaview.pdf.sign.PdfSigner
import com.vecvel.danaview.pdf.tools.PdfPageTools

class PdfToolsHostApiImpl(private val compressor: PdfCompressor? = null) : PdfToolsHostApi {
    private fun unsupported(owner: String, callback: (Result<PdfToolResultMsg>) -> Unit) =
        callback(Result.failure(PdfErrors.notSupported(owner)))

    override fun merge(request: PdfMergeRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfPageTools.OWNER, callback)

    override fun split(request: PdfSplitRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfPageTools.OWNER, callback)

    override fun reorder(request: PdfReorderRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfPageTools.OWNER, callback)

    override fun rotate(request: PdfRotateRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfPageTools.OWNER, callback)

    override fun deletePages(request: PdfDeletePagesRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        unsupported(PdfPageTools.OWNER, callback)

    override fun annotate(request: PdfAnnotateRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        unsupported(PdfAnnotator.OWNER, callback)

    override fun sign(request: PdfSignRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) = unsupported(PdfSigner.OWNER, callback)

    override fun compress(request: PdfCompressRequestMsg, callback: (Result<PdfToolResultMsg>) -> Unit) =
        compressor?.compress(request, callback) ?: unsupported(PdfCompressor.OWNER, callback)

    override fun cancel(jobId: String) {
        compressor?.cancel(jobId)
    }
}
