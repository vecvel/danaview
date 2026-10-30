// OWNER: HOM-29A
//
// Device tests of the Android annotate tool (annotate/PdfAnnotateCore.kt on PdfBox-Android, the
// Pigeon glue annotate/PdfAnnotateHostApiImpl.kt + glue/PdfToolsHostApiImpl.kt, and the viewer's
// annotate preview and annotation appearances) on the HOM-27 fixtures:
//
// - every kind (highlight, underline, strike-out with one quadrilateral per line, ink with one path
//   per stroke and /BS /W, free text with /DA and a fitted box, a text note) round-trips as a real
//   annotation with an appearance stream, at the crop box origin, readable by PdfBox and by the
//   platform renderer (API 35+: the highlight is drawn), the page text still there;
// - editable by other apps: a second PdfBox writer removes and changes them as objects, and a second
//   annotate keeps the first one's; the file's own annotations are kept;
// - encrypted in → encrypted out with the password; a file that forbids annotations → unsupported;
// - cancel at every step and failures leave no file; an existing output is never touched; sources
//   unchanged (SHA-256);
// - the viewer: the file's own Ink / FreeText / Stamp appearances are drawn over the PdfRenderer
//   tiles (pixel check in the texture's frames), our saved highlight shows before API 35 too, and an
//   annotate session's preview (ink, stamp, selection mark and handle) is drawn and removed with
//   the mode;
// - the Pigeon round trip (save and the frozen annotate: results, per-page progress with
//   tool: annotate, cancel → cancelled, replies on main) and the capabilities.

package com.vecvel.danaview.pdf.annotate

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.vecvel.danaview.pdf.glue.PdfDocumentHostApiImpl
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateSaveRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotationKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotationMsg
import com.vecvel.danaview.pdf.pigeon.PdfDisplayModeMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfInkStrokeMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignatureStampMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewMsg
import com.vecvel.danaview.pdf.pigeon.PdfTextureViewRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.pigeon.PdfViewportMsg
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import com.vecvel.danaview.pdf.text.PdfBoxTextReader
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfToolSource
import com.vecvel.danaview.pdf.viewer.FakeTextureRegistry
import com.vecvel.danaview.pdf.viewer.Fixtures
import com.vecvel.danaview.pdf.viewer.Frame
import com.vecvel.danaview.pdf.viewer.PageGeometry
import com.vecvel.danaview.pdf.viewer.PdfDocumentStore
import com.vecvel.danaview.pdf.viewer.PdfPageRenderer
import com.vecvel.danaview.pdf.viewer.PdfTextureView
import com.vecvel.danaview.pdf.viewer.PdfViewHostApiImpl
import com.vecvel.danaview.pdf.viewer.PlatformPdf
import com.vecvel.danaview.pdf.viewer.RectD
import com.vecvel.danaview.pdf.viewer.Viewport
import com.vecvel.danaview.pdf.viewer.assertCode
import com.vecvel.danaview.pdf.viewer.awaitCall
import com.vecvel.danaview.pdf.viewer.awaitComplete
import com.vecvel.danaview.pdf.viewer.isDark
import com.vecvel.danaview.pdf.viewer.isHighlight
import com.vecvel.danaview.pdf.viewer.onMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class PdfAnnotateTest {
    private lateinit var dir: File
    private lateinit var sourceHashes: Map<File, String>

    private val annotated get() = Fixtures.file(Fixtures.ANNOTATED_2)
    private val partner get() = Fixtures.file(Fixtures.MERGE_3)
    private val text200 get() = Fixtures.file(Fixtures.TEXT_200)

    @Before
    fun setUp() {
        dir = File(Fixtures.context.cacheDir, "hom29a").apply {
            deleteRecursively()
            mkdirs()
        }
        sourceHashes = listOf(annotated, partner, text200, Fixtures.encrypted).associateWith { sha(it) }
    }

    @After
    fun tearDown() {
        // Rule 27: annotate never writes to a source.
        for ((file, hash) in sourceHashes) assertEquals("source changed: ${file.name}", hash, sha(file))
        dir.deleteRecursively()
    }

    // ---- helpers ----

    private fun out(name: String) = File(dir, name)

    private fun sha(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private class Control(val cancelAt: Int = -1, val cancelWhen: () -> Boolean = { false }) : PdfToolControl {
        @Volatile var cancelled = false
        val events = CopyOnWriteArrayList<Pair<Int, Int>>()
        override val isCancelled: Boolean get() = cancelled || cancelWhen()
        override fun progress(done: Int, total: Int) {
            events += done to total
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

    private fun load(file: File, password: String? = null) = PdfBoxSupport.load(file, password)

    private fun tokens(file: File, password: String? = null): List<String> = load(file, password).use { doc ->
        val reader = PdfBoxTextReader(doc)
        (0 until doc.numberOfPages).map { i -> TOKEN.find(reader.page(i, false).text)?.value.orEmpty() }
    }

    private fun subtypes(file: File, password: String? = null): List<List<String>> =
        load(file, password).use { doc -> doc.pages.map { p -> p.annotations.map { it.subtype } } }

    private val yellow = 0xFFFFD60AL
    private val red = 0xFFE53935L

    /** The six kinds on page 0 of a 612 × 792 page, and a second ink on page 1. */
    private fun six(): List<PdfAnnotationSpec> = listOf(
        PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0, rects = listOf(PdfBox(72.0, 600.0, 200.0, 14.0), PdfBox(72.0, 584.0, 120.0, 14.0)), colorArgb = yellow),
        PdfAnnotationSpec(PdfAnnotationKind.UNDERLINE, 0, rects = listOf(PdfBox(72.0, 560.0, 200.0, 14.0)), colorArgb = 0xFF1E88E5),
        PdfAnnotationSpec(PdfAnnotationKind.STRIKE_OUT, 0, rects = listOf(PdfBox(72.0, 540.0, 200.0, 14.0)), colorArgb = red),
        PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(80.0, 400.0, 160.0, 460.0, 240.0, 400.0), doubleArrayOf(300.0, 420.0)), colorArgb = 0xFF000000, lineWidth = 3.0),
        PdfAnnotationSpec(PdfAnnotationKind.FREE_TEXT, 0, rects = listOf(PdfBox(320.0, 300.0, 150.0, 20.0)), colorArgb = red, text = "Check this figure against the appendix table"),
        PdfAnnotationSpec(PdfAnnotationKind.NOTE, 0, rects = listOf(PdfBox(500.0, 700.0, 1.0, 1.0)), colorArgb = yellow, text = "Sticky"),
        PdfAnnotationSpec(PdfAnnotationKind.INK, 1, strokes = listOf(doubleArrayOf(100.0, 300.0, 200.0, 350.0)), colorArgb = 0xFF2E7D32, lineWidth = 6.0),
    )

    private fun annotate(input: File, outFile: File, specs: List<PdfAnnotationSpec>, control: PdfToolControl = Control(), password: String? = null) =
        PdfAnnotateCore.annotate(PdfToolSource(input.path, password), specs, outPath = outFile.path, control = control)

    private fun newAnnotations(file: File, page: Int, skip: Int): List<PDAnnotation> = load(file).use { doc -> doc.getPage(page).annotations.drop(skip) }

    // ---- writing ----

    @Test
    fun everyKindRoundTripsWithAppearancesAndTheFilesOwnAreKept() {
        val o = out("six.pdf")
        val control = Control()
        val written = annotate(annotated, o, six(), control)
        assertEquals(2, written.pageCount)
        assertEquals(o.length(), written.sizeBytes)
        assertEquals(listOf(0 to 3, 1 to 3, 2 to 3, 3 to 3), control.events.toList())
        val before = subtypes(annotated)
        val after = subtypes(o)
        assertEquals(before[0] + listOf("Highlight", "Underline", "StrikeOut", "Ink", "FreeText", "Text"), after[0])
        assertEquals(before[1] + listOf("Ink"), after[1])
        assertEquals(tokens(annotated), tokens(o))
        load(o).use { doc ->
            val added = doc.getPage(0).annotations.drop(before[0].size)
            for (a in added) assertNotNull("${a.subtype} has no appearance", a.normalAppearanceStream)
            assertTrue(added.all { it.isPrinted })
            val highlight = added[0] as PDAnnotationTextMarkup
            assertEquals(16, highlight.quadPoints.size)
            assertEquals(614f, highlight.quadPoints[1], 0.01f)
            val rgb = highlight.color.components
            assertEquals(1f, rgb[0], 0.01f)
            assertEquals(214f / 255f, rgb[1], 0.01f)
            assertEquals(10f / 255f, rgb[2], 0.01f)
            assertEquals(8, (added[1] as PDAnnotationTextMarkup).quadPoints.size)
            val ink = added[3] as PDAnnotationMarkup
            assertEquals(2, ink.inkList.size)
            assertEquals(6, ink.inkList[0].size)
            assertEquals(3f, ink.borderStyle.width, 0.001f)
            assertTrue(ink.rectangle.lowerLeftX <= 80f - 3f + 0.01f && ink.rectangle.upperRightY >= 460f + 3f - 0.01f)
            val text = added[4] as PDAnnotationMarkup
            assertEquals("Check this figure against the appendix table", text.contents)
            assertTrue(text.defaultAppearance, text.defaultAppearance.startsWith("/Helv 14 Tf"))
            // The box keeps the requested top edge and width; its height fits the wrapped text.
            assertEquals(320f, text.rectangle.lowerLeftX, 0.01f)
            assertEquals(320f, text.rectangle.upperRightY, 0.01f)
            assertEquals(150f, text.rectangle.width, 0.01f)
            assertTrue("fitted to more than one line: ${text.rectangle.height}", text.rectangle.height > 40f)
            val note = added[5]
            assertEquals("Sticky", note.contents)
            assertEquals(24f, note.rectangle.width, 0.01f)
            assertEquals(before[1].size + 1, doc.getPage(1).annotations.size)
        }
    }

    @Test
    fun geometryStartsAtTheCropBoxOrigin() {
        val cropped = out("cropped_src.pdf")
        load(partner).use { doc ->
            doc.getPage(0).cropBox = PDRectangle(50f, 60f, 400f, 500f)
            doc.save(cropped)
        }
        val o = out("cropped.pdf")
        annotate(cropped, o, listOf(PdfAnnotationSpec(PdfAnnotationKind.NOTE, 0, rects = listOf(PdfBox(10.0, 20.0, 1.0, 1.0)), text = "n")))
        val note = newAnnotations(o, 0, 0).single()
        assertEquals(60f, note.rectangle.lowerLeftX, 0.01f)
        assertEquals(80f, note.rectangle.lowerLeftY, 0.01f)
    }

    @Test
    fun otherWritersCanEditTheAnnotations() {
        val o = out("first.pdf")
        annotate(annotated, o, six())
        val own = subtypes(annotated)[0].size
        // Another app (PdfBox as a plain editor) changes and removes them as objects.
        val edited = out("edited.pdf")
        load(o).use { doc ->
            val list = doc.getPage(0).annotations
            (list[own + 4] as PDAnnotationMarkup).contents = "Changed"
            list.removeAt(own + 3)
            doc.getPage(0).annotations = list
            doc.save(edited)
        }
        load(edited).use { doc ->
            val list = doc.getPage(0).annotations
            assertEquals(own + 5, list.size)
            assertEquals("Changed", list[own + 3].contents)
        }
        // A second annotate keeps the first one's annotations.
        val second = out("second.pdf")
        annotate(o, second, listOf(PdfAnnotationSpec(PdfAnnotationKind.NOTE, 1, rects = listOf(PdfBox(20.0, 20.0, 1.0, 1.0)), text = "again")))
        assertEquals(subtypes(o)[0], subtypes(second)[0])
        assertEquals(subtypes(o)[1] + "Text", subtypes(second)[1])
    }

    @Test
    fun thePlatformRendererReadsTheOutput() {
        val o = out("platform.pdf")
        annotate(partner, o, listOf(six()[0]))
        PlatformPdf.open(o, null).use { platform ->
            assertEquals(3, platform.pageCount)
            val (w, h) = platform.pageSize(0)
            val page = PageGeometry(w.toDouble(), h.toDouble(), 0)
            val scale = 1.0
            val bmp = Bitmap.createBitmap(page.width.roundToInt(), page.height.roundToInt(), Bitmap.Config.ARGB_8888)
            PdfPageRenderer.draw(platform, 0, page, scale, 0.0, 0.0, bmp)
            if (Build.VERSION.SDK_INT >= 35) {
                // From API 35 PdfRenderer draws highlight annotations itself (RenderParams flags).
                val y = (page.height - 607).roundToInt()
                var hits = 0
                for (x in 80 until 260 step 4) if (isHighlight(bmp.getPixel(x, y))) hits++
                assertTrue("highlight pixels: $hits", hits > 20)
            }
            bmp.recycle()
        }
    }

    @Test
    fun encryptedInputsStayEncryptedWithThePassword() {
        val o = out("encrypted.pdf")
        annotate(Fixtures.encrypted, o, listOf(six()[3]), password = Fixtures.USER_PASSWORD)
        assertEquals(PdfErrorCode.passwordRequired, failure { load(o).close() })
        assertEquals(PdfErrorCode.passwordRequired, failure { load(o, "wrong").close() })
        load(o, Fixtures.USER_PASSWORD).use { doc ->
            assertTrue(doc.isEncrypted)
            assertEquals("Ink", doc.getPage(0).annotations.last().subtype)
        }
        assertEquals(tokens(Fixtures.encrypted, Fixtures.USER_PASSWORD), tokens(o, Fixtures.USER_PASSWORD))
        // Without the password the input can't be read at all.
        val locked = out("locked.pdf")
        assertEquals(PdfErrorCode.passwordRequired, failure { annotate(Fixtures.encrypted, locked, listOf(six()[3])) })
        assertFalse(locked.exists())
    }

    @Test
    fun filesThatForbidAnnotationsAreUnsupported() {
        val forbidden = out("no_annots_src.pdf")
        load(partner).use { doc ->
            val perms = AccessPermission().apply { setCanModifyAnnotations(false) }
            doc.protect(StandardProtectionPolicy("owner-pw", "", perms).apply { encryptionKeyLength = 128 })
            doc.save(forbidden)
        }
        val o = out("forbidden.pdf")
        assertEquals(PdfErrorCode.unsupported, failure { annotate(forbidden, o, listOf(six()[3])) })
        assertFalse(o.exists())
        // With the owner password everything is allowed.
        annotate(forbidden, o, listOf(six()[3]), password = "owner-pw")
        assertTrue(o.exists())
    }

    @Test
    fun cancelAndFailuresLeaveNoFile() {
        // Cancel before the first page, after a page, before the write, and right after the write.
        for ((i, control) in listOf(Control(cancelAt = 0), Control(cancelAt = 1), Control(cancelAt = 2)).withIndex()) {
            val o = out("cancel_$i.pdf")
            assertEquals(PdfErrorCode.cancelled, failure { annotate(annotated, o, six(), control) })
            assertFalse(o.exists())
        }
        val late = out("cancel_late.pdf")
        assertEquals(PdfErrorCode.cancelled, failure { annotate(annotated, late, six(), Control(cancelWhen = { late.exists() })) })
        assertFalse(late.exists())

        val existing = out("existing.pdf").apply { writeText("keep") }
        assertEquals(PdfErrorCode.invalidArgument, failure { annotate(annotated, existing, six()) })
        assertEquals("keep", existing.readText())
        val bad = listOf(
            listOf(PdfAnnotationSpec(PdfAnnotationKind.NOTE, 2, rects = listOf(PdfBox(1.0, 1.0, 1.0, 1.0)), text = "x")),
            listOf(PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0)),
        )
        for ((i, specs) in bad.withIndex()) {
            val o = out("bad_$i.pdf")
            assertEquals(PdfErrorCode.invalidArgument, failure { annotate(annotated, o, specs) })
            assertFalse(o.exists())
        }
        val noImage = out("no_image.pdf")
        assertEquals(PdfErrorCode.notFound, failure {
            PdfAnnotateCore.annotate(PdfToolSource(annotated.path), emptyList(), listOf(PdfStampSpec(0, PdfBox(10.0, 10.0, 50.0, 20.0), out("missing.png").path)), outPath = noImage.path, control = Control())
        })
        val notImage = out("not_image.png").apply { writeText("not an image") }
        assertEquals(PdfErrorCode.invalidArgument, failure {
            PdfAnnotateCore.annotate(PdfToolSource(annotated.path), emptyList(), listOf(PdfStampSpec(0, PdfBox(10.0, 10.0, 50.0, 20.0), notImage.path)), outPath = noImage.path, control = Control())
        })
        assertFalse(noImage.exists())
        assertEquals(PdfErrorCode.damaged, failure { annotate(Fixtures.damaged("random"), out("damaged.pdf"), six()) })
        assertFalse(out("damaged.pdf").exists())
    }

    @Test
    fun imageStampsAreStampAnnotationsWithTheImage() {
        val png = signaturePng(out("sig.png"))
        val o = out("stamped.pdf")
        PdfAnnotateCore.annotate(PdfToolSource(partner.path), emptyList(), listOf(PdfStampSpec(0, PdfBox(100.0, 100.0, 180.0, 60.0), png.path)), outPath = o.path, control = Control())
        load(o).use { doc ->
            val stamp = doc.getPage(0).annotations.single()
            assertEquals("Stamp", stamp.subtype)
            val ap = stamp.normalAppearanceStream
            assertNotNull(ap)
            assertTrue(ap.resources.xObjectNames.iterator().hasNext())
            assertEquals(180f, stamp.rectangle.width, 0.01f)
        }
    }

    // ---- viewer ----

    private val threads = PdfThreads()
    private val store = PdfDocumentStore()
    private val textures = FakeTextureRegistry()
    private val views = PdfViewHostApiImpl(store, textures, threads)

    private fun withView(file: File, page: Int, block: (PdfTextureView, PdfTextureViewMsg) -> Unit) {
        val summary = store.open(file.path, null)
        val msg = awaitCall<PdfTextureViewMsg> { views.createTextureView(PdfTextureViewRequestMsg(summary.handle, 1080, 1600, page.toLong(), PdfDisplayModeMsg.CONTINUOUS), it) }.getOrThrow()
        try {
            val view = onMain { views.view(msg.viewId) }
            awaitComplete(view, 0)
            block(view, msg)
        } finally {
            onMain { views.disposeTextureView(msg.viewId) }
            threads.render.post { store.remove(summary.handle)?.release() }
        }
    }

    private fun frameAfter(msg: PdfTextureViewMsg, view: PdfTextureView, change: () -> Unit): Frame {
        val producer = textures.producers.single { it.id() == msg.textureId }
        // Let the frames of earlier changes land first, then wait for one drawn after [change].
        producer.settledFrame()
        val before = producer.frames.lastOrNull()?.index ?: -1
        val done = view.completeFrameCount
        change()
        awaitComplete(view, done)
        producer.awaitFrame(before)
        return producer.settledFrame(quietMs = 400)
    }

    /** [r] (PDF user space of [doc]'s page [page]) on screen in [view]. */
    private fun screenRect(view: PdfTextureView, page: Int, x: Double, y: Double, w: Double, h: Double): RectD {
        val g = view.layout.pages[page]
        val d = g.toDisplay(x, y, w, h)
        val pr = view.layout.pageRect(page)
        return view.viewport.toScreen(d.offset(pr.left, pr.top))
    }

    private fun changed(frame: Frame, ref: Bitmap, r: RectD, threshold: Int = 64): Int {
        var n = 0
        val x0 = max(0, r.left.toInt())
        val y0 = max(0, r.top.toInt())
        for (y in y0 until minOf(frame.height, r.bottom.toInt()) step 2) for (x in x0 until minOf(frame.width, r.right.toInt()) step 2) {
            val a = frame.pixel(x, y)
            val b = ref.getPixel(x, y)
            if (maxOf(abs(Color.red(a) - Color.red(b)), abs(Color.green(a) - Color.green(b)), abs(Color.blue(a) - Color.blue(b))) > threshold) n++
        }
        return n
    }

    private fun platformOnly(view: PdfTextureView, page: Int): Bitmap {
        val v = view.viewport
        val bmp = Bitmap.createBitmap(v.widthPx, v.heightPx, Bitmap.Config.ARGB_8888)
        val pr = view.layout.pageRect(page)
        PdfPageRenderer.draw(view.document.requirePlatform(), page, view.layout.pages[page], v.scale, (v.offsetX - pr.left) * v.scale, (v.offsetY - pr.top) * v.scale, bmp)
        return bmp
    }

    @Test
    fun theViewerDrawsTheFilesOwnInkFreeTextAndStampAppearances() {
        val rects = load(annotated).use { doc ->
            val crop = doc.getPage(1).cropBox
            doc.getPage(1).annotations.associate { a ->
                a.subtype to a.rectangle.let { doubleArrayOf((it.lowerLeftX - crop.lowerLeftX).toDouble(), (it.lowerLeftY - crop.lowerLeftY).toDouble(), it.width.toDouble(), it.height.toDouble()) }
            }
        }
        assertEquals(setOf("Ink", "FreeText", "Stamp"), rects.keys)
        withView(annotated, 1) { view, msg ->
            val frame = frameAfter(msg, view) { onMain { views.setTextureViewport(msg.viewId, PdfViewportMsg(1080, 1600, 0.0, view.layout.topOf(1), view.viewport.scale)) } }
            val ref = platformOnly(view, 1)
            for ((subtype, r) in rects) {
                val n = changed(frame, ref, screenRect(view, 1, r[0], r[1], r[2], r[3]))
                assertTrue("$subtype appearance not drawn ($n px)", n > 20)
            }
        }
    }

    @Test
    fun savedHighlightsShowOnEveryApiLevel() {
        val o = out("highlight_view.pdf")
        annotate(partner, o, listOf(six()[0]))
        withView(o, 0) { view, msg ->
            val frame = frameAfter(msg, view) { onMain { views.setTextureViewport(msg.viewId, PdfViewportMsg(1080, 1600, 0.0, 0.0, view.viewport.scale)) } }
            val r = screenRect(view, 0, 72.0, 600.0, 200.0, 14.0)
            var hits = 0
            val y = ((r.top + r.bottom) / 2).toInt()
            for (x in r.left.toInt() until r.right.toInt() step 3) if (isHighlight(frame.pixel(x, y))) hits++
            assertTrue("highlight pixels on API ${Build.VERSION.SDK_INT}: $hits", hits > 20)
        }
    }

    @Test
    fun theAnnotateSessionIsPreviewedAndRemovedWithTheMode() {
        val png = signaturePng(out("sig_preview.png"))
        val tools = PdfToolsHostApiImpl(threads, { })
        val host = PdfAnnotateHostApiImpl(views::view, tools)
        withView(partner, 0) { view, msg ->
            val ref = platformOnly(view, 0)
            val ink = PdfAnnotateItemMsg("ink", PdfAnnotationMsg(PdfAnnotationKindMsg.INK, 0, emptyList(), listOf(PdfInkStrokeMsg(listOf(100.0, 200.0, 400.0, 200.0))), 0xFF000000, 6.0, null))
            val stamp = PdfAnnotateItemMsg("sig", stamp = PdfSignatureStampMsg(0, PdfRectMsg(150.0, 400.0, 180.0, 60.0), png.path, 0.0))
            val shown = frameAfter(msg, view) {
                onMain {
                    host.setAnnotateMode(msg.viewId, PdfAnnotateModeMsg(PdfAnnotateInputMsg.PLACE, 0xFF000000, 3.0))
                    host.showAnnotations(msg.viewId, listOf(ink, stamp), "sig")
                }
            }
            val line = screenRect(view, 0, 100.0, 200.0, 300.0, 0.0)
            var dark = 0
            for (x in line.left.toInt() + 4 until line.right.toInt() - 4 step 4) if (isDark(shown.pixel(x, line.top.toInt()))) dark++
            assertTrue("ink preview pixels: $dark", dark > 20)
            val s = screenRect(view, 0, 150.0, 400.0, 180.0, 60.0)
            assertTrue("stamp preview", changed(shown, ref, s) > 50)
            // The handle disc (22 dp, grey hairline) at the stamp's lower trailing corner.
            val r = 11 * android.content.res.Resources.getSystem().displayMetrics.density + 4
            assertTrue("handle", changed(shown, ref, RectD(s.right - r, s.bottom - r, s.right + r, s.bottom + r), threshold = 40) > 8)
            assertTrue("no selection lines", onMain { host.selectionLines(msg.viewId) }.isEmpty())

            val cleared = frameAfter(msg, view) { onMain { host.setAnnotateMode(msg.viewId, null) } }
            dark = 0
            for (x in line.left.toInt() + 4 until line.right.toInt() - 4 step 4) if (isDark(cleared.pixel(x, line.top.toInt()))) dark++
            assertTrue("preview removed: $dark", dark < 5)
            assertEquals(null, host.mode(msg.viewId))
        }
        assertEquals("notFound", runCatching { onMain { host.setAnnotateMode(999, null) } }.exceptionOrNull()?.let { (it as com.vecvel.danaview.pdf.pigeon.PdfPigeonError).code })
    }

    // ---- Pigeon ----

    @Test
    fun hostApiSavesWithProgressCancelAndResults() {
        val events = CopyOnWriteArrayList<PdfEventMsg>()
        val tools = PdfToolsHostApiImpl(threads, events::add)
        val host = PdfAnnotateHostApiImpl(views::view, tools)
        val msgs = listOf(
            PdfAnnotationMsg(PdfAnnotationKindMsg.HIGHLIGHT, 0, listOf(PdfRectMsg(72.0, 600.0, 200.0, 14.0)), emptyList(), yellow, 0.0, null),
            PdfAnnotationMsg(PdfAnnotationKindMsg.NOTE, 1, listOf(PdfRectMsg(72.0, 600.0, 1.0, 1.0)), emptyList(), yellow, 0.0, "n"),
        )
        val o = out("pigeon.pdf")
        var main = false
        val r = awaitCall<PdfToolResultMsg> { cb ->
            host.save(PdfAnnotateSaveRequestMsg("ann", PdfToolInputMsg(partner.path, null, false), msgs, emptyList(), false, o.path)) {
                main = Looper.myLooper() == Looper.getMainLooper()
                cb(it)
            }
        }
        assertTrue(main)
        val result = r.getOrThrow()
        assertEquals(listOf(o.path), result.outPaths)
        assertEquals(listOf(3L), result.pageCounts)
        assertEquals(listOf(o.length()), result.sizesBytes)
        val progress = events.mapNotNull { it.toolProgress }.filter { it.jobId == "ann" }
        assertTrue(progress.all { it.tool == PdfToolKindMsg.ANNOTATE && it.pagesTotal == 3L })
        assertEquals(listOf(0L, 1L, 2L, 3L), progress.map { it.pagesDone })

        // The frozen PdfToolsHostApi.annotate is the same write.
        val f = out("frozen.pdf")
        awaitCall<PdfToolResultMsg> { cb -> tools.annotate(PdfAnnotateRequestMsg("frz", PdfToolInputMsg(partner.path, null, false), msgs, f.path), cb) }.getOrThrow()
        assertEquals(listOf(listOf("Highlight"), listOf("Text"), emptyList()), subtypes(f))

        // Cancel through PdfToolsHostApi.cancel.
        val c = out("pigeon_cancel.pdf")
        val many = (0 until 200).map { PdfAnnotationMsg(PdfAnnotationKindMsg.NOTE, it.toLong(), listOf(PdfRectMsg(72.0, 600.0, 1.0, 1.0)), emptyList(), yellow, 0.0, "n") }
        val cancelled = awaitCall<PdfToolResultMsg> { cb ->
            host.save(PdfAnnotateSaveRequestMsg("can", PdfToolInputMsg(text200.path, null, false), many, emptyList(), false, c.path), cb)
            tools.cancel("can")
        }
        assertCode("cancelled", cancelled)
        assertFalse(c.exists())
        assertCode("invalidArgument", awaitCall<PdfToolResultMsg> { cb -> host.save(PdfAnnotateSaveRequestMsg("bad", PdfToolInputMsg(partner.path, null, false), msgs, emptyList(), false, partner.path), cb) })
    }

    @Test
    fun capabilitiesOfferAnnotate() {
        assertTrue(PdfToolKindMsg.ANNOTATE in PdfDocumentHostApiImpl.capabilitiesMessage().tools)
    }

    @After
    fun closeViewer() {
        onMain { views.disposeAll() }
        store.removeAll().forEach { doc -> threads.render.post { doc.release() } }
        threads.render.post { threads.shutdown() }
    }

    companion object {
        val TOKEN = Regex("HOM27[A-Z]-P\\d{4}")

        /** A transparent PNG with a blue signature stroke, written to [file]. */
        fun signaturePng(file: File, w: Int = 360, h: Int = 120): File {
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            b.eraseColor(Color.TRANSPARENT)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.rgb(20, 40, 160)
                style = Paint.Style.STROKE
                strokeWidth = h / 10f
            }
            val c = Canvas(b)
            c.drawLine(w * 0.05f, h * 0.7f, w * 0.95f, h * 0.3f, paint)
            c.drawLine(w * 0.05f, h * 0.3f, w * 0.95f, h * 0.7f, paint)
            FileOutputStream(file).use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
            b.recycle()
            return file
        }
    }
}
