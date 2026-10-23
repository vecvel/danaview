// OWNER: HOM-25
//
// The platform renderer of one file (ARCH v1.2 §8 "PDF viewer", D-98g): `PdfRenderer` over a
// read-only ParcelFileDescriptor (rule 27; nothing is ever written back).
//
// - Passwords: `PdfRenderer(pfd, LoadParams)` takes one from API 35; older versions throw
//   SecurityException for a file that needs a password, which opens `locked` and stays locked
//   there (the Dart side shows the file card, `capabilities.passwords` is false; ARCH §8.4).
// - PdfRenderer is not thread-safe and keeps one page open at a time: every call runs under
//   [lock]. The last opened page stays open for the next call (tiles of one page in a row), and is
//   closed before another page is opened or the renderer closes.
// - Annotations: from API 35 the page is drawn with the text and highlight annotation flags
//   (`RenderParams`); earlier versions draw no annotations (platform behaviour). If drawing with
//   the flags ever throws, the page is drawn again without them and the document stops asking.
//   `Page.getPageAnnotations()` is NEVER called: on API 36.1+/S-ext 18 it raises a
//   NullPointerException inside its native call for Ink/FreeText/Stamp pages (HOM-27 report); the
//   exception crosses JNI and can't be caught (the API 37 emulator aborts the process), so the only
//   guard is not to call it (test/.../PdfAnnotationsGuardTest.kt keeps it out of the sources).
//
// - Text (API 35+): `getTextContents` and `selectContent` for the text layer (text/PlatformText.kt);
//   a platform failure on a page answers null / no bounds, never a crash.
//
// Nothing here logs a name, a path or document content (rule 30).

package com.vecvel.danaview.pdf.viewer

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.pdf.LoadParams
import android.graphics.pdf.PdfRenderer
import android.graphics.pdf.RenderParams
import android.graphics.pdf.models.selection.SelectionBoundary
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import java.io.Closeable
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class PlatformPdf private constructor(private val renderer: PdfRenderer) : Closeable {
    /** Guards every renderer call (callers may also hold it across several calls). */
    val lock = ReentrantLock()

    private var openPage: PdfRenderer.Page? = null
    private var closed = false

    /** Draw annotations with RenderParams (API 35+) until that fails once. */
    @Volatile var annotationsEnabled: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM
        private set

    val pageCount: Int = renderer.pageCount

    /** The displayed size of page [index] in integer points (rotation applied), as the platform reports it. */
    fun pageSize(index: Int): Pair<Int, Int> = lock.withLock {
        val page = page(index)
        page.width to page.height
    }

    /**
     * Renders page [index] into [bitmap] (ARGB_8888, already filled) through [transform], which maps
     * the page's displayed points (origin top-left, rotation applied, as the platform sizes it) to
     * bitmap pixels.
     */
    fun render(index: Int, bitmap: Bitmap, transform: Matrix) = lock.withLock {
        val page = page(index)
        if (annotationsEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            try {
                renderWithAnnotations(page, bitmap, transform)
                return@withLock
            } catch (e: RuntimeException) {
                // A platform failure drawing annotations: draw without them from now on.
                annotationsEnabled = false
                bitmap.eraseColor(android.graphics.Color.WHITE)
            }
        }
        page.render(bitmap, null, transform, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun renderWithAnnotations(page: PdfRenderer.Page, bitmap: Bitmap, transform: Matrix) {
        val params = RenderParams.Builder(RenderParams.RENDER_MODE_FOR_DISPLAY)
            .setRenderFlags(RenderParams.FLAG_RENDER_TEXT_ANNOTATIONS or RenderParams.FLAG_RENDER_HIGHLIGHT_ANNOTATIONS)
            .build()
        page.render(bitmap, null, transform, params)
    }

    /**
     * The text of page [index] as the platform reads it (API 35+; PDFium, lines end with CR LF), or
     * null when the platform fails on the page.
     */
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    fun pageText(index: Int): String? = lock.withLock {
        try {
            page(index).textContents.joinToString("") { it.text }
        } catch (e: RuntimeException) {
            null
        }
    }

    /**
     * The displayed boxes (points, origin top-left, rotation applied, the platform's page size) of
     * the characters `[start, end)` of page [index]'s platform text (API 35+), empty on failure.
     */
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    fun textBounds(index: Int, start: Int, end: Int): List<RectF> = lock.withLock {
        try {
            val selection = page(index).selectContent(SelectionBoundary(start), SelectionBoundary(end)) ?: return@withLock emptyList()
            selection.selectedTextContents.flatMap { it.bounds }
        } catch (e: RuntimeException) {
            emptyList()
        }
    }

    /** The open page [index] (call under [lock]). */
    private fun page(index: Int): PdfRenderer.Page {
        check(!closed) { "renderer closed" }
        if (index < 0 || index >= pageCount) throw PdfFailure.notFound("no such page")
        openPage?.let { if (it.index == index) return it }
        openPage?.close()
        openPage = null
        val page = try {
            renderer.openPage(index)
        } catch (e: IllegalStateException) {
            throw PdfFailure(PdfErrorCode.damaged, "page can't be opened")
        } catch (e: IllegalArgumentException) {
            throw PdfFailure(PdfErrorCode.damaged, "page can't be opened")
        }
        openPage = page
        return page
    }

    override fun close() = lock.withLock {
        if (closed) return@withLock
        closed = true
        try {
            openPage?.close()
        } catch (_: RuntimeException) {
        }
        openPage = null
        try {
            renderer.close()
        } catch (_: RuntimeException) {
        }
    }

    companion object {
        /** Whether this device's PdfRenderer takes passwords (API 35+). */
        @get:ChecksSdkIntAtLeast(api = Build.VERSION_CODES.VANILLA_ICE_CREAM)
        val supportsPasswords: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM

        /** [path] as a readable regular file: `notFound` / `ioError` otherwise. */
        fun checkFile(path: String): File {
            if (path.isEmpty()) throw PdfFailure.notFound("no such file")
            val file = File(path)
            if (!file.exists() || !file.isFile) throw PdfFailure.notFound("no such file")
            if (!file.canRead()) throw PdfFailure(PdfErrorCode.ioError, "file not readable")
            return file
        }

        /**
         * Opens [file] read-only with [password] (API 35+; ignored before). Throws `passwordRequired`
         * when the file needs a (different) password, `damaged` when it isn't a PDF the platform
         * reads, `ioError` / `notFound` for file problems.
         */
        fun open(file: File, password: String?): PlatformPdf {
            val pfd = try {
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (e: FileNotFoundException) {
                throw if (file.exists()) PdfFailure(PdfErrorCode.ioError, "file not readable") else PdfFailure.notFound("no such file")
            }
            try {
                val renderer = if (supportsPasswords && !password.isNullOrEmpty()) {
                    openWithPassword(pfd, password)
                } else {
                    PdfRenderer(pfd)
                }
                return PlatformPdf(renderer)
            } catch (e: SecurityException) {
                closeQuietly(pfd)
                throw PdfFailure(PdfErrorCode.passwordRequired, "password required")
            } catch (e: IOException) {
                closeQuietly(pfd)
                throw PdfFailure.damaged("not a readable PDF")
            } catch (e: RuntimeException) {
                closeQuietly(pfd)
                throw PdfFailure.damaged("not a readable PDF")
            }
        }

        @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
        private fun openWithPassword(pfd: ParcelFileDescriptor, password: String): PdfRenderer =
            PdfRenderer(pfd, LoadParams.Builder().setPassword(password).build())

        private fun closeQuietly(pfd: ParcelFileDescriptor) {
            try {
                pfd.close()
            } catch (_: IOException) {
            } catch (_: RuntimeException) {
            }
        }
    }
}
