// OWNER: HOM-25
//
// PdfTextHostApi on Android: the text of a page range for the search index (AIS-50's
// DocumentTextPort), read from its own read-only open of the file (rule 27; platform text from API
// 35, PdfBox before: text/PageTextSource.kt) on the text thread; the reply arrives on the main
// thread. Document text is returned, never logged (rule 30).

package com.vecvel.danaview.pdf.text

import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfPageTextMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextHostApi
import com.vecvel.danaview.pdf.pigeon.PdfTextRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextResultMsg

class PdfTextHostApiImpl(private val threads: PdfThreads) : PdfTextHostApi {
    override fun extractText(request: PdfTextRequestMsg, callback: (Result<PdfTextResultMsg>) -> Unit) {
        threads.submit(threads.text, "extractText", callback) {
            val r = PdfTextExtraction.extract(
                path = request.path,
                password = request.password,
                firstPage = clampInt(request.firstPage),
                pageCount = clampInt(request.pageCount),
                maxChars = clampInt(request.maxChars),
            )
            PdfTextResultMsg(
                documentPageCount = r.documentPageCount.toLong(),
                pages = r.pages.map { PdfPageTextMsg(it.pageIndex.toLong(), it.text) },
                truncated = r.truncated,
            )
        }
    }

    private fun clampInt(v: Long): Int = v.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
}
