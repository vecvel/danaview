// OWNER: HOM-25
//
// The open documents of one plugin instance, by handle (the Android twin of HOM-24's
// PdfDocumentStore). Each [OpenPdf] holds, for one file opened read-only (rule 27):
//
// - the platform renderer ([PlatformPdf]: pages, page sizes, drawing), null while locked;
// - the PdfBox document ([PdfFacts], outline; text before API 35), null when PdfBox can't parse a
//   file the platform can draw (then: no title, permissions allowed, no outline; no text before 35).
//
// A handle is reference-counted: `close` drops the caller's reference, every texture view holds
// its own, and the files are closed when the last one goes (off the main thread). Thread-safe.
// Nothing here logs a name, a path, a password or document text (rule 30).

package com.vecvel.danaview.pdf.viewer

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** What the Dart side learns about an open document (Pigeon `PdfDocumentInfoMsg`). */
data class PdfSummary(
    val handle: Long,
    val pageCount: Int,
    val encrypted: Boolean,
    val locked: Boolean,
    val allowsCopying: Boolean,
    val allowsPrinting: Boolean,
    val pages: List<PageGeometry>,
    val title: String?,
)

/** A cheap open-and-close result (Pigeon `PdfProbeMsg`). */
data class PdfProbeResult(val canOpen: Boolean, val encrypted: Boolean, val pageCount: Int)

/** One open file. */
class OpenPdf internal constructor(val handle: Long, val file: File) {
    private val refs = AtomicInteger(1)
    private val stateLock = Any()

    /** Guards every use of [text] (PdfBox documents are not thread-safe). */
    val textLock = ReentrantLock()

    @Volatile var platform: PlatformPdf? = null
        private set

    @Volatile var text: PDDocument? = null
        private set

    @Volatile var summary: PdfSummary = PdfSummary(handle, 0, false, true, false, false, emptyList(), null)
        private set

    /** Page texts cached by search (index → text), guarded by [textLock]. */
    internal var textCache: Array<String?>? = null
    internal var textCacheChars = 0L

    @Volatile var closed = false
        private set

    val locked: Boolean get() = platform == null

    /** The renderer, or `passwordRequired` while locked / `notFound` after close. */
    fun requirePlatform(): PlatformPdf {
        if (closed) throw PdfFailure.notFound("no such document")
        return platform ?: throw PdfFailure.locked()
    }

    /** The geometry of every page (empty while locked). */
    val pages: List<PageGeometry> get() = summary.pages

    /** Adds a reference (a view); false when the document is already closed. */
    fun retain(): Boolean {
        while (true) {
            val n = refs.get()
            if (n <= 0) return false
            if (refs.compareAndSet(n, n + 1)) return true
        }
    }

    /** Drops a reference; the last one closes the files. Returns true when this closed them. */
    fun release(): Boolean {
        if (refs.decrementAndGet() != 0) return false
        closeFiles()
        return true
    }

    /** Opens the renderer (and PdfBox) with [password]; false when the file stays locked. */
    internal fun load(password: String?): Boolean {
        val platform = try {
            PlatformPdf.open(file, password)
        } catch (f: PdfFailure) {
            if (f.code != PdfErrorCode.passwordRequired) throw f
            synchronized(stateLock) {
                summary = PdfSummary(handle, 0, true, true, false, false, emptyList(), null)
            }
            return false
        }
        try {
            var document: PDDocument? = null
            var facts: PdfFacts? = null
            try {
                document = PdfBoxSupport.load(file, password)
                facts = PdfFacts.read(document)
            } catch (f: PdfFailure) {
                // The platform draws files PdfBox can't parse: view them without its extras.
                closeQuietly(document)
                document = null
                facts = null
            } catch (e: RuntimeException) {
                closeQuietly(document)
                document = null
                facts = null
            }
            val pageCount = platform.pageCount
            val parsed = facts?.pages?.takeIf { it.size == pageCount }
            val geometry = ArrayList<PageGeometry>(pageCount)
            for (i in 0 until pageCount) {
                val p = parsed?.get(i)
                geometry += if (p != null) {
                    p
                } else {
                    val (w, h) = try {
                        platform.pageSize(i)
                    } catch (f: PdfFailure) {
                        0 to 0
                    }
                    PageGeometry.reconcile(null, w, h)
                }
            }
            synchronized(stateLock) {
                if (closed) {
                    platform.close()
                    closeQuietly(document)
                    throw PdfFailure.notFound("no such document")
                }
                this.platform = platform
                this.text = document
                summary = PdfSummary(
                    handle = handle,
                    pageCount = pageCount,
                    encrypted = facts?.encrypted ?: (password != null && password.isNotEmpty()),
                    locked = false,
                    allowsCopying = facts?.allowsCopying ?: true,
                    allowsPrinting = facts?.allowsPrinting ?: true,
                    pages = geometry,
                    title = facts?.title,
                )
            }
        } catch (t: Throwable) {
            platform.close()
            throw t
        }
        return true
    }

    private fun closeFiles() {
        val p: PlatformPdf?
        val d: PDDocument?
        synchronized(stateLock) {
            closed = true
            p = platform
            d = text
            platform = null
            text = null
        }
        p?.close()
        if (d != null) textLock.withLock {
            textCache = null
            closeQuietly(d)
        }
    }

    private fun closeQuietly(d: PDDocument?) {
        try {
            d?.close()
        } catch (_: Exception) {
        }
    }
}

class PdfDocumentStore {
    private val entries = ConcurrentHashMap<Long, OpenPdf>()
    private val nextHandle = AtomicLong(1)

    /** Number of open handles (tests). */
    val count: Int get() = entries.size

    /**
     * Opens [path] read-only (off the main thread); an encrypted file with no or a wrong password
     * opens locked.
     */
    fun open(path: String, password: String?): PdfSummary {
        val file = PlatformPdf.checkFile(path)
        val doc = OpenPdf(nextHandle.getAndIncrement(), file)
        doc.load(password)
        entries[doc.handle] = doc
        return doc.summary
    }

    /**
     * Unlocks [handle] with [password]; null when it's wrong. Before API 35 the platform renderer
     * can't open encrypted files at all: `unsupported` (the Dart side shows the file card).
     */
    fun unlock(handle: Long, password: String): PdfSummary? {
        val doc = get(handle)
        if (!doc.locked) return doc.summary
        if (!PlatformPdf.supportsPasswords) {
            throw PdfFailure(PdfErrorCode.unsupported, "encrypted PDFs need Android 15 or later")
        }
        if (password.isEmpty()) return null
        return if (doc.load(password)) doc.summary else null
    }

    /** The document of [handle] (`notFound` after `close`). */
    fun get(handle: Long): OpenPdf = entries[handle]?.takeIf { !it.closed } ?: throw PdfFailure.notFound("no such document")

    /**
     * Releases [handle] (views keep their own reference). Returns the document so the caller can
     * finish the release off the main thread, or null for an unknown handle.
     */
    fun remove(handle: Long): OpenPdf? = entries.remove(handle)

    /** Every open document (detach). */
    fun removeAll(): List<OpenPdf> {
        val all = entries.values.toList()
        entries.clear()
        return all
    }

    companion object {
        /** The viewer router's probe: never throws for a damaged file, only for a missing one. */
        fun probe(path: String): PdfProbeResult {
            val file = PlatformPdf.checkFile(path)
            return try {
                PlatformPdf.open(file, null).use { PdfProbeResult(true, false, it.pageCount) }
            } catch (f: PdfFailure) {
                when (f.code) {
                    // Encrypted: only Android 15+ can open it (with a password).
                    PdfErrorCode.passwordRequired -> PdfProbeResult(PlatformPdf.supportsPasswords, true, -1)
                    PdfErrorCode.damaged, PdfErrorCode.unsupported -> PdfProbeResult(false, false, -1)
                    else -> throw f
                }
            }
        }
    }
}
