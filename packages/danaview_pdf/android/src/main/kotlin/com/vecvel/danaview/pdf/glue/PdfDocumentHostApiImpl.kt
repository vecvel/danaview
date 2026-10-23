// OWNER: HOM-25
//
// PdfDocumentHostApi on Android over the PdfDocumentStore (viewer/PdfDocumentStore.kt): probe,
// open and unlock run on the documents pool, outline on the text thread; replies arrive on the
// main thread; sources are opened read-only (rule 27). What Android offers (capabilities):
//
//   textureView    true  - PdfRenderer tiles into a Flutter texture (viewer/PdfTextureView.kt)
//   search         true  - platform text from API 35, PdfBox before (text/PageTextSource.kt)
//   selection      false - the texture has no selectable text layer
//   outline        true  - PdfBox outline, every API level
//   passwords      API 35+ only - older PdfRenderer versions can't open encrypted files (file card)
//   textExtraction true  - as search, every API level (with a password too)
//   tools          none yet (HOM-28A..HOM-31A)

package com.vecvel.danaview.pdf.glue

import com.vecvel.danaview.pdf.annotate.PdfAnnotator
import com.vecvel.danaview.pdf.compress.PdfCompressor
import com.vecvel.danaview.pdf.pigeon.PdfCapabilitiesMsg
import com.vecvel.danaview.pdf.pigeon.PdfDocumentHostApi
import com.vecvel.danaview.pdf.pigeon.PdfDocumentInfoMsg
import com.vecvel.danaview.pdf.pigeon.PdfOpenRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfOutlineItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfPageSizeMsg
import com.vecvel.danaview.pdf.pigeon.PdfProbeMsg
import com.vecvel.danaview.pdf.sign.PdfSigner
import com.vecvel.danaview.pdf.tools.PdfPageTools
import com.vecvel.danaview.pdf.viewer.OutlineWalker
import com.vecvel.danaview.pdf.viewer.PdfDocumentStore
import com.vecvel.danaview.pdf.viewer.PdfSummary
import com.vecvel.danaview.pdf.viewer.PlatformPdf
import kotlin.concurrent.withLock

class PdfDocumentHostApiImpl(private val store: PdfDocumentStore, private val threads: PdfThreads) : PdfDocumentHostApi {
    override fun capabilities(): PdfCapabilitiesMsg = capabilitiesMessage()

    override fun probe(path: String, callback: (Result<PdfProbeMsg>) -> Unit) {
        threads.submit(threads.documents, "probe", callback) {
            val p = PdfDocumentStore.probe(path)
            PdfProbeMsg(canOpen = p.canOpen, encrypted = p.encrypted, pageCount = p.pageCount.toLong())
        }
    }

    override fun open(request: PdfOpenRequestMsg, callback: (Result<PdfDocumentInfoMsg>) -> Unit) {
        threads.submit(threads.documents, "open", callback) { message(store.open(request.path, request.password)) }
    }

    override fun unlock(handle: Long, password: String, callback: (Result<PdfDocumentInfoMsg?>) -> Unit) {
        threads.submit(threads.documents, "unlock", callback) { store.unlock(handle, password)?.let(::message) }
    }

    override fun outline(handle: Long, callback: (Result<List<PdfOutlineItemMsg>>) -> Unit) {
        threads.submit(threads.text, "outline", callback) {
            val doc = store.get(handle)
            doc.requirePlatform()
            doc.textLock.withLock {
                val text = doc.text ?: return@withLock emptyList()
                OutlineWalker.read(text).map { PdfOutlineItemMsg(it.title, it.pageIndex.toLong(), it.depth.toLong()) }
            }
        }
    }

    override fun close(handle: Long) {
        val doc = store.remove(handle) ?: return
        // The last reference closes the files, off the main thread (a render may hold the renderer).
        threads.render.post { doc.release() }
    }

    companion object {
        fun capabilitiesMessage(): PdfCapabilitiesMsg = PdfCapabilitiesMsg(
            platformView = false,
            textureView = true,
            search = true,
            selection = false,
            outline = true,
            passwords = PlatformPdf.supportsPasswords,
            textExtraction = true,
            tools = PdfPageTools.supported + PdfAnnotator.supported + PdfSigner.supported + PdfCompressor.supported,
        )

        fun message(s: PdfSummary): PdfDocumentInfoMsg = PdfDocumentInfoMsg(
            handle = s.handle,
            pageCount = s.pageCount.toLong(),
            encrypted = s.encrypted,
            locked = s.locked,
            allowsCopying = s.allowsCopying,
            allowsPrinting = s.allowsPrinting,
            pageSizes = s.pages.map { PdfPageSizeMsg(it.width, it.height, it.rotation.toLong()) },
            title = s.title,
        )
    }
}
