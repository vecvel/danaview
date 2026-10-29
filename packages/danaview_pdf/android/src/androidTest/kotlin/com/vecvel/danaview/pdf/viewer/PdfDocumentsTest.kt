// OWNER: HOM-25
//
// Instrumented tests of documents (HOM-25): open / close, page count and sizes, rotation, title,
// probe, encrypted files per API level (passwords from API 35; file card before), owner-password
// permissions, damaged files (typed errors, never a crash), the outline, and the Pigeon host API
// (replies on the main thread with the right error codes). Fixtures: PdfTestSupport.kt.

package com.vecvel.danaview.pdf.viewer

import android.os.Build
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.pdf.glue.PdfDocumentHostApiImpl
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.pigeon.PdfDocumentInfoMsg
import com.vecvel.danaview.pdf.pigeon.PdfOpenRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfOutlineItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfProbeMsg
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class PdfDocumentsTest {
    private val store = PdfDocumentStore()
    private val threads = PdfThreads()
    private val api = PdfDocumentHostApiImpl(store, threads)
    private val api35 = Build.VERSION.SDK_INT >= 35

    @After
    fun tearDown() {
        store.removeAll().forEach { it.release() }
        threads.shutdown()
    }

    private fun failureCode(block: () -> Unit): PdfErrorCode {
        try {
            block()
        } catch (f: PdfFailure) {
            return f.code
        }
        fail("expected a PdfFailure")
        error("unreachable")
    }

    @Test
    fun opens200PagesReadOnlyAndCloses() {
        val file = Fixtures.file(Fixtures.TEXT_200)
        val before = file.readBytes().contentHashCode()
        val modified = file.lastModified()
        val s = store.open(file.absolutePath, null)
        assertEquals(200, s.pageCount)
        assertFalse(s.locked)
        assertFalse(s.encrypted)
        assertTrue(s.allowsCopying)
        assertTrue(s.allowsPrinting)
        assertEquals("Danaview HOM-27 text fixture", s.title)
        assertEquals(200, s.pages.size)
        s.pages.forEach {
            assertEquals(595.0, it.width, 1.0)
            assertEquals(842.0, it.height, 1.0)
            assertEquals(0, it.rotation)
        }
        val doc = store.get(s.handle)
        assertNotNull(doc.platform)
        assertNotNull(doc.text)
        assertEquals(1, store.count)
        store.remove(s.handle)!!.release()
        assertTrue(doc.closed)
        assertEquals(PdfErrorCode.notFound, failureCode { store.get(s.handle) })
        // Rule 27: the source is untouched.
        assertEquals(before, file.readBytes().contentHashCode())
        assertEquals(modified, file.lastModified())
    }

    @Test
    fun pageGeometryAndRotationOfTheMergePartner() {
        val s = store.open(Fixtures.path(Fixtures.MERGE_3), null)
        assertEquals(3, s.pageCount)
        assertEquals(listOf(0, 0, 90), s.pages.map { it.rotation })
        assertTrue(s.pages[1].width > s.pages[1].height)
        // Page 3 is portrait A4 turned 90°: displayed landscape.
        assertTrue(s.pages[2].displayWidth > s.pages[2].displayHeight)
    }

    @Test
    fun parsedGeometryAgreesWithThePlatformRenderer() {
        for (name in listOf(Fixtures.TEXT_200, Fixtures.MERGE_3, Fixtures.ANNOTATED_2, Fixtures.IMAGES_2)) {
            val s = store.open(Fixtures.path(name), null)
            val platform = store.get(s.handle).requirePlatform()
            for (i in 0 until s.pageCount) {
                val (w, h) = platform.pageSize(i)
                val g = s.pages[i]
                assertTrue("$name page $i: ${g.displayWidth}x${g.displayHeight} vs $w x $h", abs(g.displayWidth - w) <= 1.5 && abs(g.displayHeight - h) <= 1.5)
            }
        }
    }

    @Test
    fun probeNeverThrowsForDamagedFiles() {
        assertEquals(PdfProbeResult(true, false, 200), PdfDocumentStore.probe(Fixtures.path(Fixtures.TEXT_200)))
        for (kind in Fixtures.damagedKinds) {
            val p = PdfDocumentStore.probe(Fixtures.damaged(kind).absolutePath)
            if (kind == "truncated" && p.canOpen) continue // PDFium may repair a truncated file.
            assertEquals("probe $kind", PdfProbeResult(false, false, -1), p)
        }
        assertEquals(PdfErrorCode.notFound, failureCode { PdfDocumentStore.probe(Fixtures.missing) })
        assertEquals(PdfErrorCode.notFound, failureCode { PdfDocumentStore.probe(Fixtures.file(Fixtures.TEXT_200).parent!!) })
        assertEquals(PdfErrorCode.notFound, failureCode { PdfDocumentStore.probe("") })
    }

    @Test
    fun probeOfAnEncryptedFileSaysWhetherThisDeviceCanOpenIt() {
        val p = PdfDocumentStore.probe(Fixtures.encrypted.absolutePath)
        assertTrue(p.encrypted)
        assertEquals(-1, p.pageCount)
        assertEquals(api35, p.canOpen)
    }

    @Test
    fun encryptedFileOpensLockedAndUnlocksFromApi35() {
        val locked = store.open(Fixtures.encrypted.absolutePath, null)
        assertTrue(locked.locked)
        assertTrue(locked.encrypted)
        assertEquals(0, locked.pageCount)
        assertTrue(locked.pages.isEmpty())
        assertNull(locked.title)
        val doc = store.get(locked.handle)
        assertEquals(PdfErrorCode.passwordRequired, failureCode { doc.requirePlatform() })
        if (api35) {
            assertNull(store.unlock(locked.handle, "wrong"))
            assertNull(store.unlock(locked.handle, ""))
            val unlocked = store.unlock(locked.handle, Fixtures.USER_PASSWORD)!!
            assertFalse(unlocked.locked)
            assertTrue(unlocked.encrypted)
            assertEquals(3, unlocked.pageCount)
            assertEquals(listOf(0, 0, 90), unlocked.pages.map { it.rotation })
            // Opening with the password directly.
            val direct = store.open(Fixtures.encrypted.absolutePath, Fixtures.USER_PASSWORD)
            assertFalse(direct.locked)
            assertEquals(3, direct.pageCount)
            // A wrong password opens locked.
            assertTrue(store.open(Fixtures.encrypted.absolutePath, "wrong").locked)
        } else {
            assertEquals(PdfErrorCode.unsupported, failureCode { store.unlock(locked.handle, Fixtures.USER_PASSWORD) })
            assertTrue(store.open(Fixtures.encrypted.absolutePath, Fixtures.USER_PASSWORD).locked)
        }
    }

    @Test
    fun ownerPasswordOnlyFileOpensWithItsPermissions() {
        val s = store.open(Fixtures.restricted.absolutePath, null)
        assertFalse(s.locked)
        assertTrue(s.encrypted)
        assertEquals(3, s.pageCount)
        assertFalse(s.allowsCopying)
        assertFalse(s.allowsPrinting)
    }

    @Test
    fun damagedFilesFailWithTypedErrors() {
        for (kind in Fixtures.damagedKinds) {
            val path = Fixtures.damaged(kind).absolutePath
            try {
                val s = store.open(path, null)
                // Only a truncated file may be repaired by PDFium; it must then be usable.
                assertEquals("open $kind", "truncated", kind)
                assertTrue(s.pageCount > 0)
            } catch (f: PdfFailure) {
                assertEquals("open $kind", PdfErrorCode.damaged, f.code)
            }
        }
        assertEquals(PdfErrorCode.notFound, failureCode { store.open(Fixtures.missing, null) })
    }

    @Test
    fun outlineIsFlattenedWithPageIndices() {
        val s = store.open(Fixtures.withOutline.absolutePath, null)
        val doc = store.get(s.handle)
        val entries = OutlineWalker.read(doc.text!!)
        assertEquals(
            listOf(
                OutlineEntry("Chapter 1", 0, 0),
                OutlineEntry("Section 1.1", 4, 1),
                OutlineEntry("Chapter 2", 99, 0),
                OutlineEntry("No target", -1, 0),
            ),
            entries,
        )
        val none = store.open(Fixtures.path(Fixtures.TEXT_200), null)
        assertTrue(OutlineWalker.read(store.get(none.handle).text!!).isEmpty())
    }

    @Test
    fun aViewReferenceKeepsTheDocumentOpenAfterClose() {
        val s = store.open(Fixtures.path(Fixtures.MERGE_3), null)
        val doc = store.get(s.handle)
        assertTrue(doc.retain())
        assertFalse(store.remove(s.handle)!!.release())
        assertFalse(doc.closed)
        assertNotNull(doc.requirePlatform().pageSize(0))
        assertTrue(doc.release())
        assertTrue(doc.closed)
        assertFalse(doc.retain())
    }

    @Test
    fun warmUpPdfOpensEverywhere() {
        val file = java.io.File(Fixtures.context.cacheDir, "hom25_warmup_check.pdf").apply { writeBytes(PdfWarmUp.tinyPdf()) }
        try {
            val s = store.open(file.absolutePath, null)
            assertEquals(1, s.pageCount)
            assertEquals(200.0, s.pages[0].width, 0.5)
            assertTrue(com.vecvel.danaview.pdf.text.PdfTextExtraction.extract(file.absolutePath, null, 0, -1, -1).pages[0].text.contains("Danaview"))
            PdfWarmUp.run(Fixtures.context.cacheDir)
            assertTrue(Fixtures.context.cacheDir.listFiles()!!.none { it.name.startsWith("danaview_pdf_warmup") })
        } finally {
            file.delete()
        }
    }

    // ---- Pigeon host API ----

    @Test
    fun hostApiRepliesOnTheMainThreadWithCodes() {
        val caps = api.capabilities()
        assertTrue(caps.textureView)
        assertFalse(caps.platformView)
        assertTrue(caps.search)
        assertFalse(caps.selection)
        assertTrue(caps.outline)
        assertEquals(api35, caps.passwords)
        assertTrue(caps.textExtraction)
        // The tools that have landed: compress (HOM-31A) and the page tools (HOM-28A).
        assertTrue(com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg.COMPRESS in caps.tools)
        assertTrue(caps.tools.containsAll(com.vecvel.danaview.pdf.tools.PdfPageTools.supported))

        var onMain = false
        val opened = awaitCall<PdfDocumentInfoMsg> { cb ->
            api.open(PdfOpenRequestMsg(Fixtures.path(Fixtures.MERGE_3))) { r ->
                onMain = Looper.myLooper() == Looper.getMainLooper()
                cb(r)
            }
        }.getOrThrow()
        assertTrue(onMain)
        assertEquals(3L, opened.pageCount)
        assertEquals(listOf(0L, 0L, 90L), opened.pageSizes.map { it.rotation })
        assertEquals(595.0, opened.pageSizes[2].width, 1.0)

        assertCode("notFound", awaitCall<PdfDocumentInfoMsg> { api.open(PdfOpenRequestMsg(Fixtures.missing), it) })
        assertCode("damaged", awaitCall<PdfDocumentInfoMsg> { api.open(PdfOpenRequestMsg(Fixtures.damaged("random").absolutePath), it) })
        assertEquals(PdfProbeMsg(false, false, -1), awaitCall<PdfProbeMsg> { api.probe(Fixtures.damaged("png").absolutePath, it) }.getOrThrow())
        assertCode("notFound", awaitCall<PdfProbeMsg> { api.probe(Fixtures.missing, it) })
        assertCode("notFound", awaitCall<List<PdfOutlineItemMsg>> { api.outline(9999, it) })

        val outlined = awaitCall<PdfDocumentInfoMsg> { api.open(PdfOpenRequestMsg(Fixtures.withOutline.absolutePath), it) }.getOrThrow()
        val outline = awaitCall<List<PdfOutlineItemMsg>> { api.outline(outlined.handle, it) }.getOrThrow()
        assertEquals(listOf("Chapter 1", "Section 1.1", "Chapter 2", "No target"), outline.map { it.title })
        assertEquals(listOf(0L, 4L, 99L, -1L), outline.map { it.pageIndex })
        assertEquals(listOf(0L, 1L, 0L, 0L), outline.map { it.depth })

        val locked = awaitCall<PdfDocumentInfoMsg> { api.open(PdfOpenRequestMsg(Fixtures.encrypted.absolutePath), it) }.getOrThrow()
        assertTrue(locked.locked)
        assertCode("passwordRequired", awaitCall<List<PdfOutlineItemMsg>> { api.outline(locked.handle, it) })
        val unlock = awaitCall<PdfDocumentInfoMsg?> { api.unlock(locked.handle, Fixtures.USER_PASSWORD, it) }
        if (api35) assertEquals(3L, unlock.getOrThrow()!!.pageCount) else assertCode("unsupported", unlock)

        onMain { api.close(opened.handle) }
        onMain { api.close(opened.handle) } // idempotent
        assertCode("notFound", awaitCall<List<PdfOutlineItemMsg>> { api.outline(opened.handle, it) })
    }
}
