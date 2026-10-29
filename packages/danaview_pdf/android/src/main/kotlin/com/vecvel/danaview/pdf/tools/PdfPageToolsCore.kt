// OWNER: HOM-28A
//
// The Flutter-free core of the PDF page tools on Android (HOM plan §8.5, D-98j; ARCH v1.2 rule 27),
// on PdfBox-Android 2.0.27.0 (HOM-27): merge (PDFs and images), split, and organise (reorder,
// rotate, delete, extract). The semantics follow the Apple core (darwin/Classes/Tools/
// PdfPageToolsCore.swift, HOM-28) so both platforms answer the same requests the same way.
//
// - Sources are opened read-only (`PDDocument.load(File)` only reads); their in-memory copies may be
//   changed, never saved over the source. Each tool writes only the new file(s) it is given, which
//   must not exist yet (created exclusively), once, at the end, and deletes them again on cancel or
//   failure (no partial file).
// - Pages keep their content streams (moved within the document, or deep-copied with PdfBox's
//   PDFCloneUtility), so text stays text: selectable and searchable. Nothing is rasterised.
// - Organise / reorder / rotate / delete rebuild the page tree of the loaded document itself, so the
//   catalog (outline, forms, names, metadata) survives; outline entries, links and the open action
//   that pointed at a removed page lose their destination. Split copies pages into new documents
//   with the source's metadata (as the Apple core does). Merge appends copies of the other inputs'
//   pages to the first PDF, which keeps its metadata and outline.
// - Encryption (owner-approved, HOM-29 / Mac ea3aa21c): an output made from an encrypted PDF is
//   written encrypted again. Opened with a password: that password becomes the output's user and
//   owner password (merge: its first encrypted input's). Opened without one (owner restrictions
//   only): the output opens without a password too and keeps the source's restrictions under a new
//   random owner password (PdfBox can't recover the old one).
// - Every page step polls `control.isCancelled` and reports progress. Nothing here logs; failure
//   messages are fixed debug strings without names, paths or document text (rule 30).

package com.vecvel.danaview.pdf.tools

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.multipdf.PDFCloneUtility
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDPageTree
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDMetadata
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.PDEncryption
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.interactive.action.PDActionGoTo
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationLink
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDNamedDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineNode
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Collections
import java.util.IdentityHashMap
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

/** Cancel flag and progress sink of one running tool (the glue's PdfJob). */
interface PdfToolControl {
    /** True once the caller cancelled (any thread). */
    val isCancelled: Boolean

    /** [done] of [total] pages (any thread). */
    fun progress(done: Int, total: Int)
}

/** One input of a tool. [isImage]: a JPEG, PNG, HEIC, … that becomes one page (merge only). */
data class PdfToolSource(val path: String, val password: String? = null, val isImage: Boolean = false)

/** One page of an organised document: input page [sourcePage] turned by [rotation] more degrees. */
data class PdfPagePlanItem(val sourcePage: Int, val rotation: Int = 0)

/** A file a tool wrote. */
data class PdfWrittenFile(val path: String, val pageCount: Int, val sizeBytes: Long)

/** How an output is encrypted (file header): like its encrypted source. */
internal class PdfOutputEncryption(
    private val userPassword: String,
    private val ownerPassword: String,
    private val permissions: Int,
    private val keyLength: Int,
) {
    /** Sets a fresh encryption dictionary (no stale entries of the source's) and the policy on [doc]. */
    fun apply(doc: PDDocument) {
        doc.setEncryptionDictionary(PDEncryption())
        doc.protect(
            StandardProtectionPolicy(ownerPassword, userPassword, AccessPermission(permissions)).apply {
                encryptionKeyLength = keyLength
            },
        )
    }

    companion object {
        /** The encryption of an output made from [doc], opened with [password]; null when [doc] is not encrypted. */
        fun of(doc: PDDocument, password: String?): PdfOutputEncryption? {
            if (!doc.isEncrypted) return null
            val encryption = doc.encryption
            val keyLength = if ((encryption?.length ?: 0) >= 256) 256 else 128
            val permissions = encryption?.permissions ?: AccessPermission().permissionBytes
            return if (!password.isNullOrEmpty()) {
                PdfOutputEncryption(password, password, permissions, keyLength)
            } else {
                PdfOutputEncryption("", UUID.randomUUID().toString(), permissions, keyLength)
            }
        }
    }
}

/** The page tools. */
object PdfPageToolsCore {
    /** Images become pages whose longer side is this many points (A4's long side), aspect kept. */
    const val IMAGE_PAGE_LONG_SIDE = 842f

    /** Images are downscaled to at most this many pixels on their longer side before embedding. */
    const val IMAGE_MAX_PIXELS = 4096

    /** JPEG quality of re-encoded opaque images (the Apple core's 0.9). */
    const val IMAGE_JPEG_QUALITY = 0.9f

    // ---------------------------------------------------------------------------------------------
    // Merge

    /**
     * Merges [inputs] in order into [outPath]. The first PDF keeps its metadata and outline; the pages
     * of the other inputs follow it. At least two inputs.
     */
    fun merge(inputs: List<PdfToolSource>, outPath: String, control: PdfToolControl): PdfWrittenFile {
        if (inputs.size < 2) throw PdfFailure.invalid("merge needs at least two inputs")
        checkNewFile(outPath, inputs.map { it.path })
        val opened = ArrayList<PDDocument>()
        try {
            // Open everything first, so a bad input fails before any work and the total is known.
            val parts = ArrayList<PDDocument?>()
            var total = 0
            var encryption: PdfOutputEncryption? = null
            for (input in inputs) {
                checkCancelled(control)
                if (input.isImage) {
                    checkImage(input.path)
                    parts += null
                    total += 1
                } else {
                    val doc = openForWrite(input)
                    opened += doc
                    parts += doc
                    total += doc.numberOfPages
                    if (encryption == null) encryption = PdfOutputEncryption.of(doc, input.password)
                }
            }
            val first = parts[0]
            val output = first ?: PDDocument().also { opened += it }
            if (first == null) {
                // The first input is an image: the new document takes the first PDF's metadata.
                parts.firstOrNull { it != null }?.let { copyMetadata(it, output) }
            }
            return writingNewFiles { outputs ->
                var done = if (first != null) output.numberOfPages else 0
                control.progress(done, total)
                val cloner = PDFCloneUtility(output)
                for ((i, part) in parts.withIndex()) {
                    if (i == 0 && first != null) continue
                    if (part == null) {
                        checkCancelled(control)
                        appendImage(output, inputs[i].path)
                        done++
                        control.progress(done, total)
                        continue
                    }
                    val pages = detachPages(part, control)
                    for (page in pages) {
                        checkCancelled(control)
                        output.addPage(clonePage(cloner, page))
                        done++
                        control.progress(done, total)
                    }
                }
                write(output, outPath, control, encryption, outputs)
            }
        } finally {
            opened.forEach { closeQuietly(it) }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Split

    /** Writes one file per range: `ranges[i]` (pages `[first, last]`, 0-based, inclusive) → `outPaths[i]`. */
    fun split(input: PdfToolSource, ranges: List<IntRange>, outPaths: List<String>, control: PdfToolControl): List<PdfWrittenFile> {
        if (input.isImage) throw PdfFailure.invalid("split needs a PDF")
        if (ranges.isEmpty() || ranges.size != outPaths.size) throw PdfFailure.invalid("one output per range")
        if (outPaths.map { canonical(it) }.toSet().size != outPaths.size) throw PdfFailure.invalid("duplicate output")
        for (path in outPaths) checkNewFile(path, listOf(input.path))
        val source = openForWrite(input)
        try {
            val count = source.numberOfPages
            for (range in ranges) {
                if (range.isEmpty() || range.first < 0 || range.last >= count) throw PdfFailure.invalid("range out of bounds")
            }
            val encryption = PdfOutputEncryption.of(source, input.password)
            val total = ranges.sumOf { it.last - it.first + 1 }
            return writingNewFiles { outputs ->
                var done = 0
                control.progress(0, total)
                val pages = detachPages(source, control)
                val written = ArrayList<PdfWrittenFile>()
                for ((range, path) in ranges.zip(outPaths)) {
                    val part = PDDocument()
                    try {
                        copyMetadata(source, part)
                        val cloner = PDFCloneUtility(part)
                        for (index in range) {
                            checkCancelled(control)
                            part.addPage(clonePage(cloner, pages[index]))
                            done++
                            control.progress(done, total)
                        }
                        dropDanglingDestinations(part)
                        written += write(part, path, control, encryption, outputs)
                    } finally {
                        closeQuietly(part)
                    }
                }
                written
            }
        } finally {
            closeQuietly(source)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Organise (reorder, rotate, delete, extract)

    /**
     * Writes the input's pages in the order of the plan [planFor] makes for its page count, each turned
     * by its extra rotation; pages not in the plan are left out. The document keeps its catalog
     * (metadata, outline, forms); outline entries and links to a removed page lose their destination.
     */
    fun organise(
        input: PdfToolSource,
        outPath: String,
        control: PdfToolControl,
        planFor: (pageCount: Int) -> List<PdfPagePlanItem>,
    ): PdfWrittenFile {
        if (input.isImage) throw PdfFailure.invalid("organise needs a PDF")
        checkNewFile(outPath, listOf(input.path))
        val doc = openForWrite(input)
        try {
            val count = doc.numberOfPages
            val plan = planFor(count)
            checkPlan(plan, count)
            val encryption = PdfOutputEncryption.of(doc, input.password)
            return writingNewFiles { outputs ->
                val total = plan.size
                control.progress(0, total)
                val pages = detachPages(doc, control)
                // Rebuild the page tree as one flat level in plan order (each page carries its
                // inherited attributes itself now, so the old intermediate nodes may go).
                val root = doc.documentCatalog.cosObject.getCOSDictionary(COSName.PAGES)
                    ?: throw PdfFailure.damaged("no page tree")
                root.setItem(COSName.KIDS, COSArray())
                root.setInt(COSName.COUNT, 0)
                val tree = PDPageTree(root)
                for ((done, item) in plan.withIndex()) {
                    checkCancelled(control)
                    val page = pages[item.sourcePage]
                    if (item.rotation % 360 != 0) page.rotation = normalizedRotation(page.rotation + item.rotation)
                    tree.add(page)
                    control.progress(done + 1, total)
                }
                dropDanglingDestinations(doc)
                write(doc, outPath, control, encryption, outputs)
            }
        } finally {
            closeQuietly(doc)
        }
    }

    /** Organise with a fixed [plan]. */
    fun organise(input: PdfToolSource, plan: List<PdfPagePlanItem>, outPath: String, control: PdfToolControl): PdfWrittenFile =
        organise(input, outPath, control) { plan }

    /** Fails with `invalidArgument` unless [plan] lists 1…[count] distinct pages with right-angle rotations. */
    fun checkPlan(plan: List<PdfPagePlanItem>, count: Int) {
        if (plan.isEmpty()) throw PdfFailure.invalid("at least one page must remain")
        val seen = HashSet<Int>()
        for (item in plan) {
            if (item.sourcePage < 0 || item.sourcePage >= count) throw PdfFailure.invalid("page out of bounds")
            if (!seen.add(item.sourcePage)) throw PdfFailure.invalid("page listed twice")
            if (item.rotation % 90 != 0) throw PdfFailure.invalid("rotation must be a multiple of 90")
        }
    }

    /** The plan of a reorder: `order[i]` is the page shown at position i (a permutation of all pages). */
    fun reorderPlan(order: List<Int>, pageCount: Int): List<PdfPagePlanItem> {
        if (order.size != pageCount || order.toSet() != (0 until pageCount).toSet()) {
            throw PdfFailure.invalid("order is not a permutation of the pages")
        }
        return order.map { PdfPagePlanItem(it) }
    }

    /** The plan of rotating [pages] by [degrees] (a multiple of 90; may be negative). */
    fun rotatePlan(pages: List<Int>, degrees: Int, pageCount: Int): List<PdfPagePlanItem> {
        if (degrees % 90 != 0) throw PdfFailure.invalid("rotation must be a multiple of 90")
        val set = pages.toSet()
        if (set.isEmpty() || set.any { it < 0 || it >= pageCount }) throw PdfFailure.invalid("page out of bounds")
        return (0 until pageCount).map { PdfPagePlanItem(it, if (it in set) degrees else 0) }
    }

    /** The plan of deleting [pages] (at least one page must remain). */
    fun deletePlan(pages: List<Int>, pageCount: Int): List<PdfPagePlanItem> {
        val set = pages.toSet()
        if (set.isEmpty() || set.any { it < 0 || it >= pageCount }) throw PdfFailure.invalid("page out of bounds")
        if (set.size >= pageCount) throw PdfFailure.invalid("at least one page must remain")
        return (0 until pageCount).filter { it !in set }.map { PdfPagePlanItem(it) }
    }

    /** [degrees] in 0, 90, 180, 270. */
    fun normalizedRotation(degrees: Int): Int = ((degrees % 360) + 360) % 360

    // ---------------------------------------------------------------------------------------------
    // Helpers

    /**
     * Opens a PDF input read-only, unlocked with its password, and checks that its permissions allow
     * page assembly (`unsupported` otherwise).
     */
    fun openForWrite(input: PdfToolSource): PDDocument {
        if (input.isImage) throw PdfFailure.invalid("not a PDF input")
        val file = File(input.path)
        if (!file.isFile) throw PdfFailure.notFound("no such file")
        val doc = PdfBoxSupport.load(file, input.password)
        try {
            if (!doc.currentAccessPermission.canAssembleDocument()) {
                throw PdfFailure(PdfErrorCode.unsupported, "document forbids page assembly")
            }
            if (doc.numberOfPages <= 0) throw PdfFailure.damaged("document has no pages")
        } catch (t: Throwable) {
            closeQuietly(doc)
            throw t
        }
        return doc
    }

    /**
     * The pages of [doc], each carrying its inherited attributes (media box, crop box, rotation,
     * resources) itself and no longer linked to its parent node. Copying such a page copies only
     * the page, and moving it within the page tree keeps how it looks.
     */
    internal fun detachPages(doc: PDDocument, control: PdfToolControl): List<PDPage> {
        val pages = doc.pages.toList()
        if (pages.size != doc.numberOfPages) throw PdfFailure.damaged("unreadable page tree")
        for (page in pages) {
            checkCancelled(control)
            page.mediaBox = page.mediaBox
            page.cropBox = page.cropBox
            page.rotation = page.rotation
            val resources = PDPageTree.getInheritableAttribute(page.cosObject, COSName.RESOURCES) as? COSDictionary
            page.resources = if (resources != null) PDResources(resources) else PDResources()
        }
        for (page in pages) page.cosObject.removeItem(COSName.PARENT)
        return pages
    }

    /** A copy of the detached [page] for the cloner's document (its own tagging numbers removed). */
    internal fun clonePage(cloner: PDFCloneUtility, page: PDPage): PDPage {
        val dict = cloner.cloneForNewDocument(page.cosObject) as COSDictionary
        // The destination's structure tree doesn't know these pages.
        dict.removeItem(COSName.STRUCT_PARENTS)
        (dict.getDictionaryObject(COSName.ANNOTS) as? COSArray)?.forEach { entry ->
            (deref(entry) as? COSDictionary)?.removeItem(COSName.STRUCT_PARENT)
        }
        return PDPage(dict)
    }

    /** Copies the document information and XMP metadata of [from] into [to]. */
    internal fun copyMetadata(from: PDDocument, to: PDDocument) {
        val cloner = PDFCloneUtility(to)
        (cloner.cloneForNewDocument(from.documentInformation.cosObject) as? COSDictionary)?.let {
            to.documentInformation = PDDocumentInformation(it)
        }
        from.documentCatalog.metadata?.let { metadata ->
            (cloner.cloneForNewDocument(metadata.cosObject) as? COSStream)?.let { to.documentCatalog.metadata = PDMetadata(it) }
        }
    }

    /**
     * Clears every outline entry, link and open action of [doc] that leads to a page no longer in
     * its page tree, and points annotations that name such a page as theirs (/P) at the page that
     * shows them. Otherwise those references would carry removed pages into the output.
     */
    internal fun dropDanglingDestinations(doc: PDDocument) {
        val kept: MutableSet<COSDictionary> = Collections.newSetFromMap(IdentityHashMap())
        val pages = doc.pages.toList()
        pages.forEach { kept += it.cosObject }

        fun leadsAway(destination: PDDestination?): Boolean {
            val pageDestination = when (destination) {
                is PDPageDestination -> destination
                is PDNamedDestination -> try {
                    doc.documentCatalog.findNamedDestinationPage(destination)
                } catch (_: IOException) {
                    null
                }
                else -> null
            } ?: return false
            // A page dictionary (a page number points into another file's pages: left alone).
            val target = pageDestination.cosObject.getObject(0) as? COSDictionary ?: return false
            return target !in kept
        }

        // Outline.
        fun walk(node: PDOutlineNode) {
            for (item in node.children()) {
                val action = item.action
                if (leadsAway(item.destination) || (action is PDActionGoTo && leadsAway(action.destination))) {
                    item.destination = null as PDDestination?
                    item.action = null
                }
                walk(item)
            }
        }
        try {
            doc.documentCatalog.documentOutline?.let { walk(it) }
        } catch (_: IOException) {
            // An unreadable outline is left as it is.
        }

        // Links and annotation owners on the kept pages.
        for (page in pages) {
            val annotations = try {
                page.annotations
            } catch (_: IOException) {
                continue
            }
            for (annotation in annotations) {
                val owner = annotation.cosObject.getDictionaryObject(COSName.P) as? COSDictionary
                if (owner != null && owner !in kept) annotation.cosObject.setItem(COSName.P, page.cosObject)
                if (annotation is PDAnnotationLink) {
                    val action = annotation.action
                    val away = try {
                        leadsAway(annotation.destination) || (action is PDActionGoTo && leadsAway(action.destination))
                    } catch (_: IOException) {
                        false
                    }
                    if (away) {
                        annotation.destination = null
                        annotation.action = null
                    }
                }
            }
        }

        // The open action.
        try {
            val open = doc.documentCatalog.openAction
            if ((open is PDDestination && leadsAway(open)) || (open is PDActionGoTo && leadsAway(open.destination))) {
                doc.documentCatalog.cosObject.removeItem(COSName.OPEN_ACTION)
            }
        } catch (_: IOException) {
            // Left as it is.
        }
    }

    /** Fails with `notFound` / `damaged` unless [path] is a readable image file. */
    internal fun checkImage(path: String) {
        val file = File(path)
        if (!file.isFile) throw PdfFailure.notFound("no such file")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw PdfFailure.damaged("not a readable image")
    }

    /**
     * Appends one page showing the image at [path] to [doc]: its EXIF orientation applied, downscaled
     * to [IMAGE_MAX_PIXELS], fitted to a page whose longer side is [IMAGE_PAGE_LONG_SIDE] points.
     * Opaque images are embedded as JPEG, images with transparency losslessly.
     */
    internal fun appendImage(doc: PDDocument, path: String) {
        val bitmap = decodeImage(path)
        try {
            val image = if (bitmap.hasAlpha()) {
                LosslessFactory.createFromImage(doc, bitmap)
            } else {
                JPEGFactory.createFromImage(doc, bitmap, IMAGE_JPEG_QUALITY)
            }
            val w = bitmap.width.toFloat()
            val h = bitmap.height.toFloat()
            val scale = IMAGE_PAGE_LONG_SIDE / max(w, h)
            val pw = (w * scale).roundToInt().coerceAtLeast(1).toFloat()
            val ph = (h * scale).roundToInt().coerceAtLeast(1).toFloat()
            val page = PDPage(PDRectangle(pw, ph))
            PDPageContentStream(doc, page).use { it.drawImage(image, 0f, 0f, pw, ph) }
            doc.addPage(page)
        } finally {
            bitmap.recycle()
        }
    }

    /** The image at [path], upright and at most [IMAGE_MAX_PIXELS] on its longer side. */
    internal fun decodeImage(path: String): Bitmap {
        checkImage(path)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= IMAGE_MAX_PIXELS) sample *= 2
        val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw PdfFailure.damaged("not a readable image")
        val matrix = orientationMatrix(path)
        val longSide = max(decoded.width, decoded.height)
        if (longSide > IMAGE_MAX_PIXELS) {
            val s = IMAGE_MAX_PIXELS.toFloat() / longSide
            matrix.postScale(s, s)
        }
        if (matrix.isIdentity) return decoded
        val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (upright !== decoded) decoded.recycle()
        return upright
    }

    /** The transform that turns the image at [path] upright (EXIF orientation; identity when unknown). */
    private fun orientationMatrix(path: String): Matrix {
        val matrix = Matrix()
        val orientation = try {
            ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
        }
        return matrix
    }

    /**
     * Fails with `invalidArgument` when [path] is empty, exists, or is one of [inputs]; with `notFound`
     * when its folder is missing.
     */
    fun checkNewFile(path: String, inputs: List<String>) {
        if (path.isEmpty()) throw PdfFailure.invalid("empty output path")
        val target = canonical(path)
        if (inputs.any { canonical(it) == target }) throw PdfFailure.invalid("output is an input")
        val file = File(path)
        if (file.exists()) throw PdfFailure.invalid("output exists")
        val folder = file.absoluteFile.parentFile
        if (folder == null || !folder.isDirectory) throw PdfFailure.notFound("output folder missing")
    }

    fun checkCancelled(control: PdfToolControl) {
        if (control.isCancelled) throw PdfFailure.cancelled()
    }

    /** The files a tool created so far (deleted again when it fails). */
    class Outputs internal constructor() {
        internal val created = ArrayList<File>()
    }

    /** Runs [body]; when it throws, deletes every file it created through [write], then rethrows. */
    internal fun <T> writingNewFiles(body: (Outputs) -> T): T {
        val outputs = Outputs()
        try {
            return body(outputs)
        } catch (t: Throwable) {
            outputs.created.forEach { it.delete() }
            throw t
        }
    }

    /**
     * Writes [doc] to the new file [path] (created exclusively: never over an existing file), encrypted
     * as [encryption] says; the file is registered in [outputs] as soon as it exists.
     */
    internal fun write(doc: PDDocument, path: String, control: PdfToolControl, encryption: PdfOutputEncryption?, outputs: Outputs): PdfWrittenFile {
        checkCancelled(control)
        if (encryption != null) {
            encryption.apply(doc)
        } else if (doc.isEncrypted) {
            doc.isAllSecurityToBeRemoved = true
        }
        val file = File(path)
        if (!file.createNewFile()) throw PdfFailure.invalid("output exists")
        outputs.created += file
        FileOutputStream(file).use { stream ->
            // PdfBox closes the stream it saves to; keep the file open until it is synced.
            val buffered = object : BufferedOutputStream(stream, 64 * 1024) {
                override fun close() = flush()
            }
            doc.save(buffered)
            buffered.flush()
            stream.fd.sync()
        }
        // A cancel that arrived during the write still leaves no file.
        checkCancelled(control)
        return PdfWrittenFile(path, doc.numberOfPages, file.length())
    }

    private fun canonical(path: String): String = try {
        File(path).canonicalPath
    } catch (_: IOException) {
        File(path).absolutePath
    }

    private fun deref(base: COSBase?): COSBase? =
        if (base is com.tom_roush.pdfbox.cos.COSObject) base.getObject() else base

    private fun closeQuietly(doc: PDDocument) {
        try {
            doc.close()
        } catch (_: IOException) {
        }
    }
}
