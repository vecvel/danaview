// OWNER: HOM-31A
//
// Locally generated PDFs for the HOM-31A instrumented tests (no downloads), the Android twins of
// the Apple XCTest fixtures (darwin/Tests/Compress/CompressFixtures.swift): a scanner-style file
// (one 300 dpi photo-like bitmap per US-letter page, Flate-encoded, above a line of real Helvetica
// text), a camera-style file (the same pictures as q92 JPEGs) and a text-only file (40 lines a
// page). Every page carries `token(prefix, page)` so tests can check text survives. Plus the
// HOM-27 fixtures (spikes/android_pdf/fixtures/, test assets) and small helpers: hashes, page
// text, page renders.

package com.vecvel.danaview.pdf.compress

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.math.cos
import kotlin.math.sin

const val HOM31_TAG = "HOM31"

object CompressFixtures {
    const val USER_PASSWORD = "hom31-user"
    const val OWNER_PASSWORD = "hom31-owner"

    val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    val dir: File by lazy {
        File(context.cacheDir, "hom31").apply {
            deleteRecursively()
            mkdirs()
        }
    }

    init {
        PdfBoxSupport.init(InstrumentationRegistry.getInstrumentation().targetContext)
    }

    fun token(prefix: String, index: Int) = "%s-P%04d".format(prefix, index + 1)

    /** A HOM-27 fixture (test asset) as a file. */
    fun asset(name: String): File {
        val out = File(dir, name)
        if (!out.exists()) {
            InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { input ->
                out.outputStream().use { input.copyTo(it) }
            }
        }
        return out
    }

    /** Scanner style, 3 pages, 300 ppi Flate pictures (as the Apple fixture). */
    val scan: File by lazy { imagePdf("scan.pdf", pages = 3, jpeg = false) }

    /** Camera style, 3 pages, the same pictures as q92 JPEGs. */
    val camera: File by lazy { imagePdf("camera.pdf", pages = 3, jpeg = true) }

    /** Text only, 3 pages of 40 lines. */
    val text: File by lazy { textPdf("text.pdf", pages = 3) }

    /** A photo-like opaque RGB bitmap (gradients, a soft disc, a little sensor noise), different per [seed]. */
    fun photo(width: Int, height: Int, seed: Int): Bitmap {
        val fx = (seed % 5 + 2).toDouble()
        val fy = (seed % 3 + 2).toDouble()
        val sx = DoubleArray(width) { sin(it.toDouble() / width * Math.PI * fx) }
        val cy = DoubleArray(height) { cos(it.toDouble() / height * Math.PI * fy) }
        var state = (2_654_435_761L * (seed + 1)).toInt()
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            val v = y.toDouble() / height
            for (x in 0 until width) {
                val u = x.toDouble() / width
                state = state * 1_664_525 + 1_013_904_223
                val noise = (state ushr 29) - 3.5
                val wave = sx[x] * cy[y]
                val dx = u - 0.5
                val dy = v - 0.45
                val disc = maxOf(0.0, 1 - (dx * dx + dy * dy) * 9)
                val r = (40 + 150 * u + 50 * wave + 40 * disc + noise).toInt().coerceIn(0, 255)
                val g = (60 + 120 * v + 40 * wave * disc + noise).toInt().coerceIn(0, 255)
                val b = (90 + 80 * (1 - u) * v + 70 * disc - 30 * wave + noise).toInt().coerceIn(0, 255)
                pixels[y * width + x] = Color.rgb(r, g, b)
            }
        }
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888).copy(Bitmap.Config.ARGB_8888, true)
        bitmap.setHasAlpha(false)
        return bitmap
    }

    /** [pages] US-letter pages, each a 7.5 × 9 in picture at [ppi] above one line of text. */
    fun imagePdf(name: String, pages: Int, jpeg: Boolean, ppi: Int = 300, prefix: String = "IMG", protect: StandardProtectionPolicy? = null): File {
        val out = File(dir, name)
        PDDocument().use { doc ->
            for (i in 0 until pages) {
                val page = PDPage(PDRectangle.LETTER)
                doc.addPage(page)
                val bitmap = photo(15 * ppi / 2, 9 * ppi, i)
                val image: PDImageXObject = if (jpeg) {
                    val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }.toByteArray()
                    JPEGFactory.createFromByteArray(doc, bytes)
                } else {
                    LosslessFactory.createFromImage(doc, bitmap)
                }
                bitmap.recycle()
                check(!image.cosObject.containsKey(COSName.SMASK)) { "fixture image must be opaque" }
                PDPageContentStream(doc, page).use { cs ->
                    cs.drawImage(image, 36f, 90f, 540f, 648f)
                    line(cs, "${token(prefix, i)} scanned page", 36f, 50f)
                }
            }
            if (protect != null) doc.protect(protect)
            doc.save(out)
        }
        return out
    }

    /** [pages] pages of text only (40 lines each), page i carrying `token(prefix, i)`. */
    fun textPdf(name: String, pages: Int, prefix: String = "TXT"): File {
        val out = File(dir, name)
        PDDocument().use { doc ->
            for (i in 0 until pages) {
                val page = PDPage(PDRectangle.LETTER)
                doc.addPage(page)
                PDPageContentStream(doc, page).use { cs ->
                    line(cs, "${token(prefix, i)} Danaview compress fixture", 72f, 720f)
                    for (l in 1 until 40) line(cs, "Line $l: the quick brown fox jumps over the lazy dog.", 72f, 720f - l * 16f)
                }
            }
            doc.save(out)
        }
        return out
    }

    private fun line(cs: PDPageContentStream, text: String, x: Float, y: Float) {
        cs.beginText()
        cs.setFont(PDType1Font.HELVETICA, 12f)
        cs.newLineAtOffset(x, y)
        cs.showText(text)
        cs.endText()
    }

    fun policy(owner: String, user: String, keyLength: Int, perms: AccessPermission = AccessPermission()) =
        StandardProtectionPolicy(owner, user, perms).apply { encryptionKeyLength = keyLength }

    fun sha256(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    /** The text of each page of [file] (PdfBox; opened with [password]). */
    fun pageTexts(file: File, password: String? = null): List<String> =
        PDDocument.load(file, password ?: "").use { doc ->
            val stripper = PDFTextStripper()
            (1..doc.numberOfPages).map { p ->
                stripper.startPage = p
                stripper.endPage = p
                stripper.getText(doc)
            }
        }

    /** Page 0 of [file] rendered at 200 × 260 on white (platform renderer; unencrypted files). */
    fun render(file: File): IntArray {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { renderer ->
                renderer.openPage(0).use { page ->
                    val bitmap = Bitmap.createBitmap(200, 260, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val px = IntArray(200 * 260)
                    bitmap.getPixels(px, 0, 200, 0, 0, 200, 260)
                    bitmap.recycle()
                    return px
                }
            }
        }
    }

    /** Mean absolute difference (0…255) of page 0 of [a] and [b]. */
    fun pageDifference(a: File, b: File): Double {
        val pa = render(a)
        val pb = render(b)
        var total = 0L
        for (i in pa.indices) {
            total += Math.abs(Color.red(pa[i]) - Color.red(pb[i])) + Math.abs(Color.green(pa[i]) - Color.green(pb[i])) +
                Math.abs(Color.blue(pa[i]) - Color.blue(pb[i]))
        }
        return total.toDouble() / (pa.size * 3)
    }
}
