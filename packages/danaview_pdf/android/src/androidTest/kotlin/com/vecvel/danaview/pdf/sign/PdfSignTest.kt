// OWNER: HOM-30A
//
// Device tests of the Android sign (sign/PdfSigner.kt → the HOM-29A annotate save with burnIn,
// annotate/PdfAnnotateCore.kt) on the HOM-27 fixtures: the signature image is in the page content
// (PdfRenderer draws it: its pixels in the rect), no annotation is added (no /Stamp left), the page's
// own annotations, crop box, media box and /Rotate stay, the page text is still extracted; a
// quarter-turned signature on a /Rotate 90 page fills its rect; burned-in ink leaves no Ink
// annotation; encrypted in → encrypted out; a file that forbids changes → unsupported; empty
// requests, missing images and cancel leave no file; the Pigeon sign (progress `tool: sign`) and
// the burn-in save; capabilities. Sources unchanged (SHA-256).

package com.vecvel.danaview.pdf.sign

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.vecvel.danaview.pdf.annotate.PdfAnnotateCore
import com.vecvel.danaview.pdf.annotate.PdfAnnotateHostApiImpl
import com.vecvel.danaview.pdf.annotate.PdfAnnotateTest
import com.vecvel.danaview.pdf.annotate.PdfAnnotationKind
import com.vecvel.danaview.pdf.annotate.PdfAnnotationSpec
import com.vecvel.danaview.pdf.annotate.PdfBox
import com.vecvel.danaview.pdf.glue.PdfDocumentHostApiImpl
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateSaveRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignatureStampMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import com.vecvel.danaview.pdf.text.PdfBoxTextReader
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfToolSource
import com.vecvel.danaview.pdf.viewer.Fixtures
import com.vecvel.danaview.pdf.viewer.PageGeometry
import com.vecvel.danaview.pdf.viewer.PdfPageRenderer
import com.vecvel.danaview.pdf.viewer.PlatformPdf
import com.vecvel.danaview.pdf.viewer.RectD
import com.vecvel.danaview.pdf.viewer.assertCode
import com.vecvel.danaview.pdf.viewer.awaitCall
import com.vecvel.danaview.pdf.viewer.isDark
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class PdfSignTest {
    private lateinit var dir: File
    private lateinit var sourceHashes: Map<File, String>
    private lateinit var sig: File

    private val annotated get() = Fixtures.file(Fixtures.ANNOTATED_2)
    private val partner get() = Fixtures.file(Fixtures.MERGE_3)

    @Before
    fun setUp() {
        dir = File(Fixtures.context.cacheDir, "hom30a").apply {
            deleteRecursively()
            mkdirs()
        }
        sig = PdfAnnotateTest.signaturePng(File(dir, "sig.png"))
        sourceHashes = listOf(annotated, partner, Fixtures.encrypted, sig).associateWith { sha(it) }
    }

    @After
    fun tearDown() {
        for ((file, hash) in sourceHashes) assertEquals("source changed: ${file.name}", hash, sha(file))
        dir.deleteRecursively()
    }

    // ---- helpers ----

    private fun out(name: String) = File(dir, name)

    private fun sha(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private class Control(val cancelAt: Int = -1) : PdfToolControl {
        @Volatile var cancelled = false
        override val isCancelled: Boolean get() = cancelled
        override fun progress(done: Int, total: Int) {
            if (cancelAt >= 0 && done >= cancelAt) cancelled = true
        }
    }

    private fun failure(block: () -> Unit): PdfErrorCode {
        try {
            block()
        } catch (f: PdfFailure) {
            return f.code
        }
        fail("expected a PdfFailure")
        error("unreachable")
    }

    private fun stamp(page: Int, x: Double, y: Double, w: Double, h: Double, rotation: Double = 0.0, image: File = sig) =
        PdfSignatureStampMsg(page.toLong(), PdfRectMsg(x, y, w, h), image.path, rotation)

    private fun sign(input: File, o: File, stamps: List<PdfSignatureStampMsg>, password: String? = null, control: PdfToolControl = Control()) =
        PdfSigner.sign(PdfSignRequestMsg("s", PdfToolInputMsg(input.path, password, false), stamps, o.path), control).single()

    private data class PageFacts(val subtypes: List<String>, val crop: List<Float>, val media: List<Float>, val rotation: Int, val text: String)

    private fun facts(file: File, password: String? = null): List<PageFacts> = PdfBoxSupport.load(file, password).use { doc ->
        val boxes = doc.pages.map { p -> Triple(p.annotations.map { it.subtype }, p.cropBox, p.mediaBox) to p.rotation }
        val reader = PdfBoxTextReader(doc)
        boxes.mapIndexed { i, (b, rotation) ->
            fun PDRectangle.list() = listOf(lowerLeftX, lowerLeftY, upperRightX, upperRightY)
            PageFacts(b.first, b.second.list(), b.third.list(), rotation, PdfAnnotateTest.TOKEN.find(reader.page(i, false).text)?.value.orEmpty())
        }
    }

    /** Page [index] of [file] as PdfRenderer draws it at 1 px per point, with its geometry. */
    private fun render(file: File, index: Int): Pair<Bitmap, PageGeometry> {
        val geometry = PdfBoxSupport.load(file, null).use { doc ->
            val p = doc.getPage(index)
            PageGeometry(p.cropBox.width.toDouble(), p.cropBox.height.toDouble(), p.rotation)
        }
        PlatformPdf.open(file, null).use { platform ->
            val bmp = Bitmap.createBitmap(geometry.displayWidth.roundToInt(), geometry.displayHeight.roundToInt(), Bitmap.Config.ARGB_8888)
            PdfPageRenderer.draw(platform, index, geometry, 1.0, 0.0, 0.0, bmp)
            return bmp to geometry
        }
    }

    private fun isInk(c: Int) = Color.blue(c) > 110 && Color.red(c) < 110 && Color.green(c) < 120

    private fun count(bmp: Bitmap, r: RectD, test: (Int) -> Boolean): Int {
        var n = 0
        for (y in maxOf(0, r.top.toInt()) until minOf(bmp.height, r.bottom.toInt())) {
            for (x in maxOf(0, r.left.toInt()) until minOf(bmp.width, r.right.toInt())) if (test(bmp.getPixel(x, y))) n++
        }
        return n
    }

    // ---- tests ----

    @Test
    fun theSignatureIsBurnedIntoThePageWithNoAnnotationLeft() {
        val o = out("signed.pdf")
        val written = sign(annotated, o, listOf(stamp(0, 300.0, 60.0, 180.0, 60.0), stamp(1, 60.0, 500.0, 180.0, 60.0)))
        assertEquals(2, written.pageCount)
        val before = facts(annotated)
        val after = facts(o)
        // The page's own annotations (incl. its own /Approved Stamp on page 2), boxes, rotation and text stay; nothing is added.
        assertEquals(before, after)
        val (bmp, g) = render(o, 0)
        val r = g.toDisplay(300.0, 60.0, 180.0, 60.0)
        assertTrue("signature pixels in the content", count(bmp, r, ::isInk) > 300)
        val (plain, _) = render(annotated, 0)
        assertEquals("no ink there before", 0, count(plain, r, ::isInk))
        bmp.recycle()
        plain.recycle()
    }

    @Test
    fun aQuarterTurnedSignatureFillsItsRectOnARotatedPage() {
        // merge_partner page 3 is /Rotate 90: a signature upright on screen is turned 90° in page space.
        val o = out("rotated.pdf")
        sign(partner, o, listOf(stamp(2, 200.0, 300.0, 60.0, 180.0, rotation = 90.0)))
        assertEquals(facts(partner), facts(o))
        val (bmp, g) = render(o, 2)
        assertEquals(90, g.rotation)
        val r = g.toDisplay(200.0, 300.0, 60.0, 180.0)
        assertEquals(180.0, r.width, 0.5)
        val inside = count(bmp, r, ::isInk)
        assertTrue("signature inside: $inside", inside > 300)
        // It fills the rect: ink near both ends of the long side, none beyond it.
        assertTrue(count(bmp, RectD(r.left, r.top, r.left + 30, r.bottom), ::isInk) > 20)
        assertTrue(count(bmp, RectD(r.right - 30, r.top, r.right, r.bottom), ::isInk) > 20)
        val around = RectD(r.left - 60, r.top - 60, r.right + 60, r.bottom + 60)
        assertTrue("ink outside the rect", count(bmp, around, ::isInk) - count(bmp, RectD(r.left - 3, r.top - 3, r.right + 3, r.bottom + 3), ::isInk) < 10)
        bmp.recycle()
    }

    @Test
    fun theCropBoxOriginIsHonoured() {
        val cropped = out("cropped_src.pdf")
        PdfBoxSupport.load(partner, null).use { doc ->
            doc.getPage(0).cropBox = PDRectangle(50f, 60f, 400f, 500f)
            doc.save(cropped)
        }
        val o = out("cropped.pdf")
        sign(cropped, o, listOf(stamp(0, 20.0, 30.0, 180.0, 60.0)))
        assertEquals(facts(cropped), facts(o))
        val (bmp, g) = render(o, 0)
        assertEquals(400.0, g.width, 0.01)
        assertTrue(count(bmp, g.toDisplay(20.0, 30.0, 180.0, 60.0), ::isInk) > 300)
        bmp.recycle()
    }

    @Test
    fun burnedInInkLeavesNoInkAnnotation() {
        val o = out("ink_burned.pdf")
        PdfAnnotateCore.annotate(
            PdfToolSource(partner.path),
            listOf(PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(100.0, 400.0, 400.0, 400.0)), colorArgb = 0xFF000000, lineWidth = 6.0)),
            burnIn = true,
            outPath = o.path,
            control = Control(),
        )
        assertEquals(facts(partner), facts(o))
        val (bmp, g) = render(o, 0)
        val (plain, _) = render(partner, 0)
        // The 6 pt stroke from x 100 to 400 at y 400 (page space), drawn where the annotation was.
        val band = g.toDisplay(96.0, 395.0, 308.0, 10.0)
        val added = count(bmp, band, ::isDark) - count(plain, band, ::isDark)
        assertTrue("ink pixels added in place: $added", added > 1000)
        plain.recycle()
        bmp.recycle()
    }

    @Test
    fun encryptedInStaysEncrypted() {
        val o = out("encrypted_signed.pdf")
        sign(Fixtures.encrypted, o, listOf(stamp(0, 100.0, 100.0, 180.0, 60.0)), password = Fixtures.USER_PASSWORD)
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfBoxSupport.load(o, null).close() })
        PdfBoxSupport.load(o, Fixtures.USER_PASSWORD).use { doc ->
            assertTrue(doc.isEncrypted)
            assertTrue(doc.getPage(0).annotations.isEmpty())
            assertTrue(doc.getPage(0).resources.xObjectNames.iterator().hasNext())
        }
        assertEquals(facts(Fixtures.encrypted, Fixtures.USER_PASSWORD), facts(o, Fixtures.USER_PASSWORD))
    }

    @Test
    fun forbiddenChangesBadRequestsAndCancelLeaveNoFile() {
        val noChanges = out("no_changes_src.pdf")
        PdfBoxSupport.load(partner, null).use { doc ->
            val perms = AccessPermission().apply { setCanModify(false) }
            doc.protect(StandardProtectionPolicy("owner-pw", "", perms).apply { encryptionKeyLength = 128 })
            doc.save(noChanges)
        }
        val o = out("out.pdf")
        assertEquals(PdfErrorCode.unsupported, failure { sign(noChanges, o, listOf(stamp(0, 10.0, 10.0, 50.0, 20.0))) })
        assertEquals(PdfErrorCode.invalidArgument, failure { sign(partner, o, emptyList()) })
        assertEquals(PdfErrorCode.invalidArgument, failure { sign(partner, o, listOf(stamp(3, 10.0, 10.0, 50.0, 20.0))) })
        assertEquals(PdfErrorCode.invalidArgument, failure { sign(partner, o, listOf(stamp(0, 10.0, 10.0, 0.0, 20.0))) })
        assertEquals(PdfErrorCode.notFound, failure { sign(partner, o, listOf(stamp(0, 10.0, 10.0, 50.0, 20.0, image = out("none.png")))) })
        assertEquals(PdfErrorCode.invalidArgument, failure { sign(partner, partner, listOf(stamp(0, 10.0, 10.0, 50.0, 20.0))) })
        for (at in 0..1) {
            assertEquals(PdfErrorCode.cancelled, failure { sign(partner, o, listOf(stamp(0, 10.0, 10.0, 50.0, 20.0)), control = Control(cancelAt = at)) })
        }
        assertFalse(o.exists())
    }

    @Test
    fun pigeonSignAndBurnInSave() {
        val threads = PdfThreads()
        try {
            val events = CopyOnWriteArrayList<PdfEventMsg>()
            val tools = PdfToolsHostApiImpl(threads, events::add)
            val o = out("pigeon_signed.pdf")
            val r = awaitCall<PdfToolResultMsg> { cb -> tools.sign(PdfSignRequestMsg("sg", PdfToolInputMsg(partner.path, null, false), listOf(stamp(0, 100.0, 100.0, 180.0, 60.0)), o.path), cb) }
            assertEquals(listOf(3L), r.getOrThrow().pageCounts)
            val progress = events.mapNotNull { it.toolProgress }.filter { it.jobId == "sg" }
            assertTrue(progress.isNotEmpty() && progress.all { it.tool == PdfToolKindMsg.SIGN })
            assertEquals(1.0, progress.last().fraction, 1e-9)
            assertEquals(facts(partner), facts(o))
            assertCode("invalidArgument", awaitCall<PdfToolResultMsg> { cb -> tools.sign(PdfSignRequestMsg("e", PdfToolInputMsg(partner.path, null, false), emptyList(), out("e.pdf").path), cb) })

            // The Dart sign mode saves through PdfAnnotateHostApi.save(stamps, burnIn: true).
            val host = PdfAnnotateHostApiImpl({ throw IllegalStateException() }, tools)
            val b = out("pigeon_burn.pdf")
            awaitCall<PdfToolResultMsg> { cb ->
                host.save(PdfAnnotateSaveRequestMsg("bn", PdfToolInputMsg(annotated.path, null, false), emptyList(), listOf(stamp(1, 60.0, 500.0, 180.0, 60.0)), true, b.path), cb)
            }.getOrThrow()
            assertEquals(facts(annotated), facts(b))
            val c = out("pigeon_cancel.pdf")
            val cancelled = awaitCall<PdfToolResultMsg> { cb ->
                tools.sign(PdfSignRequestMsg("cx", PdfToolInputMsg(Fixtures.file(Fixtures.TEXT_200).path, null, false), (0 until 200).map { stamp(it, 10.0, 10.0, 90.0, 30.0) }, c.path), cb)
                tools.cancel("cx")
            }
            assertCode("cancelled", cancelled)
            assertFalse(c.exists())
        } finally {
            threads.shutdown()
        }
    }

    @Test
    fun capabilitiesOfferSign() {
        assertTrue(PdfToolKindMsg.SIGN in PdfDocumentHostApiImpl.capabilitiesMessage().tools)
        assertEquals(listOf(PdfToolKindMsg.SIGN), PdfSigner.supported)
    }
}
