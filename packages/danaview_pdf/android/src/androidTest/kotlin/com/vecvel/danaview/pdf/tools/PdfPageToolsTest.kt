// OWNER: HOM-28A
//
// Device tests of the Android page tools (tools/PdfPageToolsCore.kt over PdfBox-Android, and the
// Pigeon glue glue/PdfToolsHostApiImpl.kt) on the HOM-27 fixtures (spikes/android_pdf/fixtures/,
// test assets): merge (200 + 3, PDFs with images), split (ranges, overlaps, every page), reorder,
// rotate (existing /Rotate kept and added to), delete, organise; text kept (each page's token read
// back with the plugin's own PdfBox text reader, which reads /Rotate pages unrotated, HOM-25 / HOM-27
// note); annotations kept; encrypted in → encrypted out with the same password; cancel and failure
// leave no file; sources unchanged (SHA-256); progress on every page; capabilities. Timings are
// logged under the HOM28A tag (`adb logcat -s HOM28A`).

package com.vecvel.danaview.pdf.tools

import android.graphics.Bitmap
import android.graphics.Color
import android.media.ExifInterface
import android.os.Build
import android.os.Looper
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfOrganiseRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfPagePlanMsg
import com.vecvel.danaview.pdf.pigeon.PdfReorderRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfRotateRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import com.vecvel.danaview.pdf.text.PdfBoxTextReader
import com.vecvel.danaview.pdf.viewer.Fixtures
import com.vecvel.danaview.pdf.viewer.assertCode
import com.vecvel.danaview.pdf.viewer.awaitCall
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class PdfPageToolsTest {
    private lateinit var dir: File
    private lateinit var sourceHashes: Map<File, String>

    private val text200 get() = Fixtures.file(Fixtures.TEXT_200)
    private val partner get() = Fixtures.file(Fixtures.MERGE_3)
    private val annotated get() = Fixtures.file(Fixtures.ANNOTATED_2)
    private val images get() = Fixtures.file(Fixtures.IMAGES_2)

    @Before
    fun setUp() {
        dir = File(Fixtures.context.cacheDir, "hom28a").apply {
            deleteRecursively()
            mkdirs()
        }
        sourceHashes = listOf(text200, partner, annotated, images, Fixtures.encrypted, Fixtures.restricted, Fixtures.withOutline)
            .associateWith { sha(it) }
    }

    @After
    fun tearDown() {
        // Rule 27: no tool ever writes to a source.
        for ((file, hash) in sourceHashes) assertEquals("source changed: ${file.name}", hash, sha(file))
        dir.deleteRecursively()
    }

    // ---- helpers ----

    private fun out(name: String) = File(dir, name)

    private fun src(file: File, password: String? = null) = PdfToolSource(file.absolutePath, password)

    private fun sha(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    /** Records progress; cancels once [cancelAt] pages are done (or when [cancelWhen] holds). */
    private class Control(val cancelAt: Int = -1, val cancelWhen: () -> Boolean = { false }, val onProgress: (Int, Int) -> Unit = { _, _ -> }) :
        PdfToolControl {
        @Volatile var cancelled = false
        val events = CopyOnWriteArrayList<Pair<Int, Int>>()

        override val isCancelled: Boolean get() = cancelled || cancelWhen()

        override fun progress(done: Int, total: Int) {
            events += done to total
            if (cancelAt >= 0 && done >= cancelAt) cancelled = true
            onProgress(done, total)
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

    private fun <T> timed(label: String, block: () -> T): T {
        val t0 = System.nanoTime()
        val r = block()
        val ms = (System.nanoTime() - t0) / 1_000_000
        Log.i(TAG, "timing api=${Build.VERSION.SDK_INT} $label ms=$ms")
        return r
    }

    /** Each page's fixture tokens (HOM27T-P0001, …), read by the plugin's PdfBox text reader. */
    private fun tokens(file: File, password: String? = null): List<String> =
        PdfBoxSupport.load(file, password).use { doc ->
            val reader = PdfBoxTextReader(doc)
            (0 until doc.numberOfPages).map { i -> TOKEN.findAll(reader.page(i, false).text).map { it.value }.distinct().joinToString(",") }
        }

    private fun rotations(file: File, password: String? = null): List<Int> =
        PdfBoxSupport.load(file, password).use { doc -> doc.pages.map { it.rotation } }

    private fun subtypes(file: File, password: String? = null): List<List<String>> =
        PdfBoxSupport.load(file, password).use { doc -> doc.pages.map { p -> p.annotations.map { it.subtype } } }

    private fun expected(prefix: String, pages: Iterable<Int>) = pages.map { "%s-P%04d".format(prefix, it + 1) }

    private fun assertProgressEveryPage(control: Control, from: Int, total: Int) {
        val done = control.events.map { it.first }
        assertTrue("totals ${control.events.map { it.second }.distinct()}", control.events.all { it.second == total })
        assertEquals((from..total).toList(), done)
    }

    private fun assertNoFiles(vararg files: File) = files.forEach { assertFalse("left ${it.name}", it.exists()) }

    // ---- merge ----

    @Test
    fun merge200Plus3KeepsTextOrderAndRotation() {
        val o = out("merged.pdf")
        val control = Control()
        val written = timed("merge_200+3") { PdfPageToolsCore.merge(listOf(src(text200), src(partner)), o.path, control) }
        assertEquals(203, written.pageCount)
        assertEquals(o.length(), written.sizeBytes)
        assertEquals(expected("HOM27T", 0 until 200) + expected("HOM27M", 0 until 3), tokens(o))
        assertEquals(List(200) { 0 } + listOf(0, 0, 90), rotations(o))
        // The partner's landscape page 2 stays landscape.
        PDDocument.load(o).use { doc ->
            val box = doc.getPage(201).mediaBox
            assertTrue(box.width > box.height)
        }
        assertProgressEveryPage(control, 200, 203)
    }

    @Test
    fun mergePdfsAndImagesKeepsAnnotationsAndOrientsImages() {
        val jpeg = out("photo.jpg")
        Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(200, 30, 30)) }.let { b ->
            jpeg.outputStream().use { b.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        }
        // Stored landscape, shown portrait (EXIF: rotate 90 clockwise).
        ExifInterface(jpeg.path).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val png = out("badge.png")
        Bitmap.createBitmap(400, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.argb(128, 0, 0, 255)) }.let { b ->
            png.outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val o = out("mixed.pdf")
        val control = Control()
        val inputs = listOf(
            src(annotated),
            src(images),
            PdfToolSource(jpeg.path, isImage = true),
            PdfToolSource(png.path, isImage = true),
            src(partner),
        )
        val written = timed("merge_annotated+scans+2images+partner") { PdfPageToolsCore.merge(inputs, o.path, control) }
        assertEquals(9, written.pageCount)
        assertProgressEveryPage(control, 2, 9)
        val subs = subtypes(o)
        assertEquals(subtypes(annotated), subs.take(2))
        assertEquals(7, subs.take(2).flatten().size)
        val toks = tokens(o)
        assertEquals(expected("HOM27A", 0 until 2), toks.take(2))
        assertEquals(listOf("", "", "", ""), toks.subList(2, 6))
        assertEquals(expected("HOM27M", 0 until 3), toks.takeLast(3))
        assertEquals(listOf(0, 0, 0, 0, 0, 0, 0, 0, 90), rotations(o))
        PDDocument.load(o).use { doc ->
            val photo = doc.getPage(4).mediaBox
            assertTrue("EXIF orientation applied: ${photo.width}x${photo.height}", photo.height > photo.width)
            assertEquals(842f, photo.height, 0.5f)
            val badge = doc.getPage(5).mediaBox
            assertEquals(842f, badge.width, 0.5f)
            assertEquals(421f, badge.height, 0.5f)
        }
        // An image first: a new document, the first PDF's pages after it.
        val o2 = out("image_first.pdf")
        val w2 = PdfPageToolsCore.merge(listOf(PdfToolSource(jpeg.path, isImage = true), src(partner)), o2.path, Control())
        assertEquals(4, w2.pageCount)
        assertEquals(listOf("") + expected("HOM27M", 0 until 3), tokens(o2))
    }

    // ---- split ----

    @Test
    fun splitWritesEachRangeIncludingOverlaps() {
        val a = out("a.pdf")
        val b = out("b.pdf")
        val control = Control()
        val parts = timed("split_1-100_101-200") { PdfPageToolsCore.split(src(text200), listOf(0..99, 100..199), listOf(a.path, b.path), control) }
        assertEquals(listOf(100, 100), parts.map { it.pageCount })
        assertEquals(listOf(a.length(), b.length()), parts.map { it.sizeBytes })
        assertEquals(expected("HOM27T", 0 until 100), tokens(a))
        assertEquals(expected("HOM27T", 100 until 200), tokens(b))
        assertTrue("a part is about half the file", a.length() < text200.length() * 0.7)
        assertProgressEveryPage(control, 0, 200)

        val c = out("c.pdf")
        val d = out("d.pdf")
        PdfPageToolsCore.split(src(partner), listOf(0..1, 1..2), listOf(c.path, d.path), Control())
        assertEquals(expected("HOM27M", 0..1), tokens(c))
        assertEquals(expected("HOM27M", 1..2), tokens(d))
        assertEquals(listOf(0, 90), rotations(d))

        val e = out("annotated_p2.pdf")
        PdfPageToolsCore.split(src(annotated), listOf(1..1), listOf(e.path), Control())
        assertEquals(subtypes(annotated).drop(1), subtypes(e))
    }

    @Test
    fun splitEveryPageOf200() {
        val outs = (1..200).map { out("p$it.pdf").path }
        val parts = timed("split_every_page_200") { PdfPageToolsCore.split(src(text200), (0 until 200).map { it..it }, outs, Control()) }
        assertEquals(200, parts.size)
        assertTrue(parts.all { it.pageCount == 1 })
        assertEquals(listOf("HOM27T-P0001"), tokens(File(outs[0])))
        assertEquals(listOf("HOM27T-P0200"), tokens(File(outs[199])))
    }

    // ---- reorder / rotate / delete / organise ----

    @Test
    fun reorderMovesPagesWithTheirRotation() {
        val o = out("reordered.pdf")
        val control = Control()
        timed("reorder_3_1_2") { PdfPageToolsCore.organise(src(partner), o.path, control) { PdfPageToolsCore.reorderPlan(listOf(2, 0, 1), it) } }
        assertEquals(listOf("HOM27M-P0003", "HOM27M-P0001", "HOM27M-P0002"), tokens(o))
        assertEquals(listOf(90, 0, 0), rotations(o))
        assertProgressEveryPage(control, 0, 3)

        val r = out("reversed.pdf")
        val reverse = (199 downTo 0).toList()
        timed("reorder_reverse_200") { PdfPageToolsCore.organise(src(text200), r.path, Control()) { PdfPageToolsCore.reorderPlan(reverse, it) } }
        assertEquals(expected("HOM27T", reverse), tokens(r))
    }

    @Test
    fun rotateAddsToTheExistingRotation() {
        val o = out("rotated.pdf")
        timed("rotate_p1_p3_by_90") { PdfPageToolsCore.organise(src(partner), o.path, Control()) { PdfPageToolsCore.rotatePlan(listOf(0, 2), 90, it) } }
        assertEquals(listOf(90, 0, 180), rotations(o))
        assertEquals(expected("HOM27M", 0 until 3), tokens(o))

        val n = out("rotated_neg.pdf")
        PdfPageToolsCore.organise(src(partner), n.path, Control()) { PdfPageToolsCore.rotatePlan(listOf(0, 2), -90, it) }
        assertEquals(listOf(270, 0, 0), rotations(n))

        val all = out("rotated_200.pdf")
        val control = Control()
        timed("rotate_all_200") { PdfPageToolsCore.organise(src(text200), all.path, control) { PdfPageToolsCore.rotatePlan((0 until 200).toList(), 90, it) } }
        assertEquals(List(200) { 90 }, rotations(all))
        assertEquals(expected("HOM27T", 0 until 200), tokens(all))
        assertProgressEveryPage(control, 0, 200)

        val ann = out("annotated_rotated.pdf")
        PdfPageToolsCore.organise(src(annotated), ann.path, Control()) { PdfPageToolsCore.rotatePlan(listOf(1), 180, it) }
        assertEquals(subtypes(annotated), subtypes(ann))
        assertEquals(listOf(0, 180), rotations(ann))
    }

    @Test
    fun deleteDropsPagesAndTheirContent() {
        val o = out("deleted.pdf")
        timed("delete_p2_of_3") { PdfPageToolsCore.organise(src(partner), o.path, Control()) { PdfPageToolsCore.deletePlan(listOf(1), it) } }
        assertEquals(listOf("HOM27M-P0001", "HOM27M-P0003"), tokens(o))
        assertEquals(listOf(0, 90), rotations(o))

        val half = out("deleted_100.pdf")
        val odd = (0 until 200).filter { it % 2 == 1 }
        val written = timed("delete_100_of_200") { PdfPageToolsCore.organise(src(text200), half.path, Control()) { PdfPageToolsCore.deletePlan(odd, it) } }
        assertEquals(100, written.pageCount)
        assertEquals(expected("HOM27T", (0 until 200).filter { it % 2 == 0 }), tokens(half))
        assertTrue("removed pages are not carried: ${half.length()}", half.length() < text200.length() * 0.7)
    }

    @Test
    fun organiseReordersRotatesAndDropsInOnePass() {
        val o = out("organised.pdf")
        val control = Control()
        val plan = listOf(PdfPagePlanItem(2, 90), PdfPagePlanItem(0, 0))
        val written = timed("organise_partner") { PdfPageToolsCore.organise(src(partner), plan, o.path, control) }
        assertEquals(2, written.pageCount)
        assertEquals(listOf("HOM27M-P0003", "HOM27M-P0001"), tokens(o))
        assertEquals(listOf(180, 0), rotations(o))
        assertProgressEveryPage(control, 0, 2)

        val a = out("annotated_swapped.pdf")
        PdfPageToolsCore.organise(src(annotated), listOf(PdfPagePlanItem(1), PdfPagePlanItem(0, -90)), a.path, Control())
        assertEquals(subtypes(annotated).reversed(), subtypes(a))
        assertEquals(listOf(0, 270), rotations(a))
        assertEquals(listOf("HOM27A-P0002", "HOM27A-P0001"), tokens(a))
    }

    @Test
    fun outlineEntriesToRemovedPagesLoseTheirDestination() {
        val o = out("outline_deleted.pdf")
        PdfPageToolsCore.organise(src(Fixtures.withOutline), o.path, Control()) { PdfPageToolsCore.deletePlan(listOf(99), it) }
        PDDocument.load(o).use { doc ->
            assertEquals(199, doc.numberOfPages)
            val items = doc.documentCatalog.documentOutline.children().associateBy { it.title }
            val ch1 = items.getValue("Chapter 1").destination as PDPageDestination
            assertEquals(0, doc.pages.indexOf(ch1.page))
            assertNull(items.getValue("Chapter 2").destination)
            val section = items.getValue("Chapter 1").children().first().destination as PDPageDestination
            assertEquals(4, doc.pages.indexOf(section.page))
        }
    }

    // ---- encryption ----

    @Test
    fun encryptedInputsStayEncryptedWithTheSamePassword() {
        val pw = Fixtures.USER_PASSWORD
        val enc = Fixtures.encrypted
        val o = out("enc_organised.pdf")
        PdfPageToolsCore.organise(src(enc, pw), listOf(PdfPagePlanItem(1), PdfPagePlanItem(0)), o.path, Control())
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfBoxSupport.load(o, null).close() })
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfBoxSupport.load(o, "wrong").close() })
        assertEquals(listOf("HOM27M-P0002", "HOM27M-P0001"), tokens(o, pw))
        PdfBoxSupport.load(o, pw).use { assertTrue(it.isEncrypted) }

        val s = out("enc_split.pdf")
        PdfPageToolsCore.split(src(enc, pw), listOf(2..2), listOf(s.path), Control())
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfBoxSupport.load(s, null).close() })
        assertEquals(listOf("HOM27M-P0003"), tokens(s, pw))
        assertEquals(listOf(90), rotations(s, pw))

        // Merge: the first encrypted input's password, wherever it sits.
        val m = out("enc_merged.pdf")
        PdfPageToolsCore.merge(listOf(src(annotated), src(enc, pw)), m.path, Control())
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfBoxSupport.load(m, null).close() })
        assertEquals(expected("HOM27A", 0 until 2) + expected("HOM27M", 0 until 3), tokens(m, pw))

        // Without the password, or with a wrong one: passwordRequired and no file.
        val x = out("enc_nopw.pdf")
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfPageToolsCore.organise(src(enc), listOf(PdfPagePlanItem(0)), x.path, Control()) })
        assertEquals(PdfErrorCode.passwordRequired, failure { PdfPageToolsCore.merge(listOf(src(partner), src(enc, "nope")), x.path, Control()) })
        assertNoFiles(x)

        // AES-256 stays AES-256.
        val aes = out("aes256_src.pdf")
        PDDocument.load(partner).use { doc ->
            doc.protect(StandardProtectionPolicy("own256", "user256", AccessPermission()).apply { encryptionKeyLength = 256 })
            doc.save(aes)
        }
        val a = out("aes256_out.pdf")
        PdfPageToolsCore.organise(src(aes, "user256"), a.path, Control()) { PdfPageToolsCore.rotatePlan(listOf(0), 90, it) }
        PdfBoxSupport.load(a, "user256").use { doc ->
            assertEquals(256, doc.encryption.length)
            assertEquals(listOf(90, 0, 90), doc.pages.map { it.rotation })
        }
        assertEquals(expected("HOM27M", 0 until 3), tokens(a, "user256"))
    }

    @Test
    fun ownerRestrictedInputsKeepTheirRestrictions() {
        val o = out("restricted_out.pdf")
        PdfPageToolsCore.organise(src(Fixtures.restricted), listOf(PdfPagePlanItem(2), PdfPagePlanItem(0)), o.path, Control())
        PdfBoxSupport.load(o, null).use { doc ->
            assertTrue(doc.isEncrypted)
            assertFalse(doc.currentAccessPermission.canExtractContent())
            assertFalse(doc.currentAccessPermission.canPrint())
        }
        assertEquals(listOf("HOM27M-P0003", "HOM27M-P0001"), tokens(o))
    }

    @Test
    fun noPageAssemblyIsUnsupported() {
        val locked = out("no_assembly.pdf")
        PDDocument.load(partner).use { doc ->
            doc.protect(StandardProtectionPolicy("owner", "", AccessPermission().apply { setCanAssembleDocument(false) }).apply { encryptionKeyLength = 128 })
            doc.save(locked)
        }
        val o = out("na.pdf")
        assertEquals(PdfErrorCode.unsupported, failure { PdfPageToolsCore.organise(src(locked), listOf(PdfPagePlanItem(0)), o.path, Control()) })
        assertEquals(PdfErrorCode.unsupported, failure { PdfPageToolsCore.split(src(locked), listOf(0..0), listOf(o.path), Control()) })
        assertEquals(PdfErrorCode.unsupported, failure { PdfPageToolsCore.merge(listOf(src(partner), src(locked)), o.path, Control()) })
        assertNoFiles(o)
        // The owner password grants it.
        PdfPageToolsCore.organise(src(locked, "owner"), listOf(PdfPagePlanItem(0)), o.path, Control())
        assertTrue(o.exists())
    }

    // ---- cancel and failure ----

    @Test
    fun cancelMidJobLeavesNoFile() {
        val o = out("cancelled.pdf")
        val reverse = (199 downTo 0).toList()
        assertEquals(PdfErrorCode.cancelled, failure { PdfPageToolsCore.organise(src(text200), o.path, Control(cancelAt = 50)) { PdfPageToolsCore.reorderPlan(reverse, it) } })
        assertNoFiles(o)

        // Split: the first part was already written when the cancel came; both are gone.
        val a = out("a.pdf")
        val b = out("b.pdf")
        val control = Control(cancelAt = 150)
        assertEquals(PdfErrorCode.cancelled, failure { PdfPageToolsCore.split(src(text200), listOf(0..99, 100..199), listOf(a.path, b.path), control) })
        assertTrue(control.events.any { it.first == 100 })
        assertNoFiles(a, b)

        val m = out("merge_cancelled.pdf")
        assertEquals(PdfErrorCode.cancelled, failure { PdfPageToolsCore.merge(listOf(src(text200), src(partner)), m.path, Control(cancelAt = 201)) })
        assertNoFiles(m)

        // A cancel that arrives while the file is being written: the written file is deleted.
        val w = out("cancel_in_write.pdf")
        assertEquals(PdfErrorCode.cancelled, failure { PdfPageToolsCore.organise(src(partner), listOf(PdfPagePlanItem(0)), w.path, Control(cancelWhen = { w.exists() })) })
        assertNoFiles(w)
    }

    @Test
    fun failuresLeaveNoFile() {
        val o = out("failed.pdf")
        // Damaged, missing and non-image inputs.
        for (kind in Fixtures.damagedKinds) {
            val result = try {
                PdfPageToolsCore.merge(listOf(src(partner), src(Fixtures.damaged(kind))), o.path, Control())
            } catch (f: PdfFailure) {
                assertTrue("$kind: ${f.code}", f.code == PdfErrorCode.damaged || f.code == PdfErrorCode.notFound)
                assertNoFiles(o)
                null
            }
            if (result != null) {
                // PdfBox's lenient parser salvages what it can (the truncated file): a readable output.
                assertEquals("only the truncated file is salvaged", "truncated", kind)
                assertEquals(expected("HOM27M", 0 until 3), tokens(o).take(3))
                o.delete()
            }
        }
        assertEquals(PdfErrorCode.notFound, failure { PdfPageToolsCore.merge(listOf(src(partner), PdfToolSource(Fixtures.missing)), o.path, Control()) })
        val notImage = out("noise.jpg").apply { writeBytes(ByteArray(4096) { (it * 31).toByte() }) }
        assertEquals(PdfErrorCode.damaged, failure { PdfPageToolsCore.merge(listOf(src(partner), PdfToolSource(notImage.path, isImage = true)), o.path, Control()) })
        // Bad output paths.
        assertEquals(PdfErrorCode.notFound, failure { PdfPageToolsCore.organise(src(partner), listOf(PdfPagePlanItem(0)), File(dir, "nope/x.pdf").path, Control()) })
        assertEquals(PdfErrorCode.invalidArgument, failure { PdfPageToolsCore.organise(src(partner), listOf(PdfPagePlanItem(0)), partner.path, Control()) })
        val existing = out("existing.pdf").apply { writeText("keep me") }
        assertEquals(PdfErrorCode.invalidArgument, failure { PdfPageToolsCore.organise(src(partner), listOf(PdfPagePlanItem(0)), existing.path, Control()) })
        assertEquals("keep me", existing.readText())
        // Bad plans.
        assertEquals(PdfErrorCode.invalidArgument, failure { PdfPageToolsCore.organise(src(partner), listOf(PdfPagePlanItem(3)), o.path, Control()) })
        assertEquals(PdfErrorCode.invalidArgument, failure { PdfPageToolsCore.organise(src(partner), o.path, Control()) { PdfPageToolsCore.deletePlan(listOf(0, 1, 2), it) } })
        assertEquals(PdfErrorCode.invalidArgument, failure { PdfPageToolsCore.split(src(partner), listOf(2..3), listOf(o.path), Control()) })
        // A write that fails (its folder vanished mid-job): ioError, nothing left.
        val folder = File(dir, "vanishing").apply { mkdirs() }
        val v = File(folder, "v.pdf")
        val code = try {
            PdfPageToolsCore.organise(src(text200), v.path, Control(onProgress = { done, _ -> if (done == 100) folder.deleteRecursively() })) {
                PdfPageToolsCore.rotatePlan(listOf(0), 90, it)
            }
            null
        } catch (e: java.io.IOException) {
            "io"
        }
        assertEquals("io", code)
        assertNoFiles(v, o)
    }

    // ---- through Pigeon ----

    @Test
    fun hostApiRunsJobsWithProgressCancelAndResults() {
        val threads = PdfThreads()
        val events = CopyOnWriteArrayList<PdfEventMsg>()
        val api = PdfToolsHostApiImpl(threads, events::add)
        try {
            val o = out("pigeon_rotated.pdf")
            var onMain = false
            val r = awaitCall<PdfToolResultMsg> { cb ->
                api.rotate(PdfRotateRequestMsg("rot", PdfToolInputMsg(partner.path, null, false), listOf(1L), 90L, o.path)) {
                    onMain = Looper.myLooper() == Looper.getMainLooper()
                    cb(it)
                }
            }
            assertTrue(onMain)
            val result = r.getOrThrow()
            assertEquals(listOf(o.path), result.outPaths)
            assertEquals(listOf(3L), result.pageCounts)
            assertEquals(listOf(o.length()), result.sizesBytes)
            assertEquals(listOf(0, 90, 90), rotations(o))
            val progress = events.mapNotNull { it.toolProgress }.filter { it.jobId == "rot" }
            assertEquals(listOf(0L, 1L, 2L, 3L), progress.map { it.pagesDone })
            assertTrue(progress.all { it.tool == PdfToolKindMsg.ROTATE && it.pagesTotal == 3L })
            assertEquals(1.0, progress.last().fraction, 1e-9)

            // Organise reports `tool: reorder`.
            val g = out("pigeon_organised.pdf")
            val og = awaitCall<PdfToolResultMsg> { cb ->
                api.organise(PdfOrganiseRequestMsg("org", PdfToolInputMsg(partner.path, null, false), listOf(PdfPagePlanMsg(2, 0), PdfPagePlanMsg(1, 90)), g.path), cb)
            }
            assertEquals(listOf(2L), og.getOrThrow().pageCounts)
            assertTrue(events.mapNotNull { it.toolProgress }.filter { it.jobId == "org" }.all { it.tool == PdfToolKindMsg.REORDER })

            // Cancel through PdfToolsHostApi.cancel: `cancelled`, no file, the id free again.
            val c = out("pigeon_cancelled.pdf")
            val reverse = (199L downTo 0L).toList()
            val cancelled = awaitCall<PdfToolResultMsg> { cb ->
                api.reorder(PdfReorderRequestMsg("rev", PdfToolInputMsg(text200.path, null, false), reverse, c.path), cb)
                api.cancel("rev")
            }
            assertCode("cancelled", cancelled)
            assertNoFiles(c)
            assertEquals(0, api.jobs.runningCount)

            // Errors keep their codes; a running id can't be reused.
            assertCode("notFound", awaitCall<PdfToolResultMsg> { cb -> api.reorder(PdfReorderRequestMsg("nf", PdfToolInputMsg(Fixtures.missing, null, false), listOf(0L), out("nf.pdf").path), cb) })
            val first = out("dup1.pdf")
            val second = awaitCall<PdfToolResultMsg> { cb ->
                api.reorder(PdfReorderRequestMsg("dup", PdfToolInputMsg(text200.path, null, false), reverse, first.path)) { }
                api.reorder(PdfReorderRequestMsg("dup", PdfToolInputMsg(partner.path, null, false), listOf(0L, 1L, 2L), out("dup2.pdf").path), cb)
                api.cancel("dup")
            }
            assertCode("invalidArgument", second)
            assertNoFiles(out("dup2.pdf"))
        } finally {
            threads.shutdown()
        }
    }

    @Test
    fun capabilitiesOfferThePageTools() {
        assertNotNull(PdfPageTools.supported)
        assertEquals(
            setOf(PdfToolKindMsg.MERGE, PdfToolKindMsg.SPLIT, PdfToolKindMsg.REORDER, PdfToolKindMsg.ROTATE, PdfToolKindMsg.DELETE_PAGES),
            PdfPageTools.supported.toSet(),
        )
    }

    private companion object {
        const val TAG = "HOM28A"
        val TOKEN = Regex("HOM27[A-Z]-P\\d{4}")
    }
}
