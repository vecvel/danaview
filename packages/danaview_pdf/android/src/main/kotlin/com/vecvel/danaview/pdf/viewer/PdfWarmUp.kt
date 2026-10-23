// OWNER: HOM-25
//
// Warms the PDF code paths once per process so the first document a user opens is not also the
// first time PdfBox's parser and the platform renderer run (cold first page on the API 28 emulator:
// ~600 ms, warm ~200 ms). The plugin starts it a few seconds after attach on a low-priority
// background thread: a tiny built-in one-page PDF (no user file) is parsed with PdfBox, its facts
// read, and its page drawn into a small bitmap with PdfRenderer from a temporary copy in the app's
// cache, which is deleted at once. Failures are ignored; nothing is logged.

package com.vecvel.danaview.pdf.viewer

import android.graphics.Bitmap
import android.graphics.Matrix
import com.tom_roush.pdfbox.pdmodel.PDDocument
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

object PdfWarmUp {
    private val done = AtomicBoolean(false)

    /** Runs once per process (later calls return at once); call off the main thread. */
    fun run(cacheDir: File) {
        if (!done.compareAndSet(false, true)) return
        val bytes = tinyPdf()
        try {
            PDDocument.load(bytes).use { PdfFacts.read(it) }
        } catch (_: Exception) {
        }
        val file = File(cacheDir, "danaview_pdf_warmup_${android.os.Process.myPid()}.pdf")
        try {
            file.writeBytes(bytes)
            PlatformPdf.open(file, null).use { platform ->
                val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
                platform.lock.lock()
                try {
                    platform.render(0, bitmap, Matrix().apply { setScale(0.1f, 0.1f) })
                } finally {
                    platform.lock.unlock()
                }
                bitmap.recycle()
            }
        } catch (_: Exception) {
        } finally {
            file.delete()
        }
    }

    /** A valid one-page PDF with a line of Helvetica text, built with correct xref offsets. */
    fun tinyPdf(): ByteArray {
        val content = "BT /F1 12 Tf 20 40 Td (Danaview) Tj ET"
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length ${content.length} >>\nstream\n$content\nendstream",
        )
        val out = ByteArrayOutputStream()
        fun write(s: String) = out.write(s.toByteArray(Charsets.ISO_8859_1))
        write("%PDF-1.4\n")
        val offsets = ArrayList<Int>()
        objects.forEachIndexed { i, body ->
            offsets += out.size()
            write("${i + 1} 0 obj\n$body\nendobj\n")
        }
        val xref = out.size()
        write("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
        offsets.forEach { write("%010d 00000 n \n".format(it)) }
        write("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
        return out.toByteArray()
    }
}
