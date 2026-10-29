// OWNER: HOM-31A
//
// PDF compress on Android (HOM plan §8.5, D-98j; BUILD_PLAN HOM-31A, BUILD_STATE "S4: HOM-31
// compress", Android contract) on PdfBox-Android 2.0.27.0, the HOM-27 write engine. Flutter-free
// so the instrumented tests drive it directly.
//
// Only image XObjects change: each eligible one is decoded, scaled to the preset's resolution and
// re-encoded as a baseline JPEG at the preset's quality, in place (the image object keeps its
// number, so every page, form and name that uses it sees the new picture). Content streams, fonts,
// vectors, annotations and the outline are written back as PdfBox read them: text stays
// selectable and searchable. An image is replaced only when that saves at least 10 %. Masked,
// stencil, decode-array, CMYK, indexed, 1-bit and JPX / JBIG2 / CCITT images are left alone.
//
// The presets follow the Apple engine's intent (darwin/Classes/Compress/PdfCompressCore.swift):
// High keeps every pixel at high quality; Medium caps images at about 144 dpi as placed on the
// page (PDFKit's "optimise for screen") at medium quality; Small does the same, then scales by
// 0.67 at a lower quality. An image whose placement is unknown (patterns, annotations) gets the
// Apple fallback scale (1 / 0.75 / 0.5). The JPEGs come from `Bitmap.compress`, never from
// `JPEGFactory.createFromImage`, which adds a lossless alpha mask for the ARGB bitmaps PdfBox
// decodes to (HOM-27: the file grows).
//
// The source is opened read-only (rule 27). `outPath` must not exist; it is created once, at the
// end, and deleted again if anything fails. When no image is replaced the output is a byte copy of
// the source, so a text-only file never grows. An encrypted source is written back encrypted: with
// its password as both user and owner password (as on Apple), or, for a file that opens with the
// empty user password (owner restrictions only), with the empty user password, the same
// permissions and a fresh random owner password. PdfBox's scratch buffers live in the caller's
// [scratchDir], which the caller removes. Nothing is logged (rule 30).

package com.vecvel.danaview.pdf.compress

import android.graphics.Bitmap
import android.graphics.Rect
import com.tom_roush.pdfbox.contentstream.PDFStreamEngine
import com.tom_roush.pdfbox.contentstream.operator.DrawObject
import com.tom_roush.pdfbox.contentstream.operator.Operator
import com.tom_roush.pdfbox.contentstream.operator.state.Concatenate
import com.tom_roush.pdfbox.contentstream.operator.state.Restore
import com.tom_roush.pdfbox.contentstream.operator.state.Save
import com.tom_roush.pdfbox.contentstream.operator.state.SetGraphicsStateParameters
import com.tom_roush.pdfbox.contentstream.operator.state.SetMatrix
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSBoolean
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.IdentityHashMap
import java.util.UUID

/** The compression presets (pigeons/pdf_api.dart `PdfCompressPresetMsg`, same order). */
enum class PdfCompressPreset { HIGH, MEDIUM, SMALL }

/**
 * What one preset does to an image.
 *
 * @property quality JPEG quality for `Bitmap.compress` (0…100).
 * @property dpiCap images placed above this resolution are scaled down to it first; null keeps it.
 * @property scale pixel scale applied after the cap.
 * @property fallbackScale the whole scale for an image whose placement on a page is unknown.
 */
data class PdfCompressSettings(val quality: Int, val dpiCap: Double?, val scale: Double, val fallbackScale: Double) {
    /** The pixel scale (0.05…1) for an image shown at [dpi] at its largest placement, or null when unknown. */
    fun scaleFor(dpi: Double?): Double {
        val s = if (dpi == null || dpi <= 0.0 || dpi.isNaN() || dpi.isInfinite()) {
            fallbackScale
        } else {
            val cap = dpiCap
            (if (cap != null && dpi > cap) cap / dpi else 1.0) * scale
        }
        return s.coerceIn(MIN_SCALE, 1.0)
    }

    companion object {
        const val MIN_SCALE = 0.05

        /** A replaced image must be at most this fraction of the original's encoded bytes. */
        const val MINIMUM_SAVING = 0.9

        /**
         * The settings of [preset]. Qualities are Android's libjpeg scale, which gives far fewer
         * bytes per step than Apple's ImageIO scale (a q0.92 ImageIO photo is about twice the
         * size of a q92 libjpeg one), so they are tuned by result on the HOM-31A fixtures: High
         * q85 (HOM-27's value; q75 measured too, rendered pages differed by 0.3-0.4 / 255 but it
         * is the codec's mid default, not "high"), Medium q60, Small q45 (Apple's numbers).
         */
        fun of(preset: PdfCompressPreset): PdfCompressSettings = when (preset) {
            PdfCompressPreset.HIGH -> PdfCompressSettings(quality = 85, dpiCap = null, scale = 1.0, fallbackScale = 1.0)
            PdfCompressPreset.MEDIUM -> PdfCompressSettings(quality = 60, dpiCap = 144.0, scale = 1.0, fallbackScale = 0.75)
            PdfCompressPreset.SMALL -> PdfCompressSettings(quality = 45, dpiCap = 144.0, scale = 0.67, fallbackScale = 0.5)
        }
    }
}

/** The facts of one image XObject that decide whether it is re-encoded (pure, unit-tested). */
data class PdfImageFacts(
    val width: Int,
    val height: Int,
    val bitsPerComponent: Int,
    /** Colour components of the colour space, or null for one we don't re-encode (CMYK counts 4). */
    val components: Int?,
    /** Filter names in decode order, without the leading slash. */
    val filters: List<String>,
    val stencil: Boolean,
    val masked: Boolean,
    val softMasked: Boolean,
    val hasDecode: Boolean,
    val hasAlternates: Boolean,
    val external: Boolean,
)

/** The pure rules of the compressor (unit-tested on the JVM). */
object PdfCompressRules {
    /** Images smaller than this on a side are left alone (icons, rules). */
    const val MINIMUM_SIDE = 16

    /** Files with at most this many pages are estimated by compressing all of them (as on Apple). */
    const val FULL_ESTIMATE_PAGES = 4

    /** Filters whose images we decode and re-encode; JPX, JBIG2 and CCITT pass through. */
    private val decodable = setOf("FlateDecode", "Fl", "DCTDecode", "DCT", "LZWDecode", "LZW", "ASCIIHexDecode", "AHx", "ASCII85Decode", "A85", "RunLengthDecode", "RL")

    /** True when the image is worth decoding and re-encoding as an RGB JPEG. */
    fun eligible(f: PdfImageFacts): Boolean {
        if (f.stencil || f.masked || f.softMasked || f.hasDecode || f.hasAlternates || f.external) return false
        if (f.bitsPerComponent != 8) return false
        if (f.components != 1 && f.components != 3) return false
        if (f.width < MINIMUM_SIDE || f.height < MINIMUM_SIDE) return false
        return f.filters.all { it in decodable }
    }

    /** The scaled size of a [width] × [height] image. */
    fun targetSize(width: Int, height: Int, scale: Double): Pair<Int, Int> =
        Pair(maxOf(1, Math.round(width * scale).toInt()), maxOf(1, Math.round(height * scale).toInt()))

    /** The decode subsampling that keeps a [width] × [height] image within [budgetPixels]. */
    fun subsampling(width: Int, height: Int, budgetPixels: Long): Int {
        val pixels = width.toLong() * height.toLong()
        if (budgetPixels <= 0 || pixels <= budgetPixels) return 1
        var s = 2
        while (pixels / (s.toLong() * s) > budgetPixels) s++
        return s
    }

    /** The decode budget in pixels for a heap of [maxMemory] bytes (about 12 bytes a pixel, half the heap). */
    fun budgetPixels(maxMemory: Long): Long = (maxMemory / 2 / 12).coerceIn(1_000_000L, 40_000_000L)

    /** True when [newBytes] saves enough over [oldBytes]. */
    fun worthReplacing(newBytes: Long, oldBytes: Long): Boolean =
        newBytes > 0 && newBytes.toDouble() <= oldBytes.toDouble() * PdfCompressSettings.MINIMUM_SAVING

    /** The resolution (dpi) of a [pixelsWide] × [pixelsHigh] image drawn [pointsWide] × [pointsHigh] (the lower axis). */
    fun placedDpi(pixelsWide: Int, pixelsHigh: Int, pointsWide: Double, pointsHigh: Double): Double? {
        if (pointsWide < 0.5 || pointsHigh < 0.5) return null
        return minOf(pixelsWide * 72.0 / pointsWide, pixelsHigh * 72.0 / pointsHigh)
    }

    /** The 0-based pages an estimate samples from a [count]-page file (evenly spread, as on Apple). */
    fun samplePages(count: Int): List<Int> {
        if (count <= 0) return emptyList()
        if (count <= FULL_ESTIMATE_PAGES) return (0 until count).toList()
        return (0 until FULL_ESTIMATE_PAGES).map { it * (count - 1) / (FULL_ESTIMATE_PAGES - 1) }.distinct().sorted()
    }

    /** [sourceBytes] scaled by what compressing a sample did to it ([sampleBytes] of [baselineBytes]). */
    fun scaledEstimate(sourceBytes: Long, sampleBytes: Long, baselineBytes: Long): Long {
        if (baselineBytes <= 0) return sourceBytes
        return Math.round(sourceBytes.toDouble() * sampleBytes.toDouble() / baselineBytes.toDouble())
    }

    /** The job fraction after [done] of [total] pages (2 % for opening, 90 % for the pages, the rest for the write). */
    fun pageFraction(done: Int, total: Int): Double =
        if (total <= 0) PAGES_START else PAGES_START + PAGES_SHARE * done.coerceIn(0, total) / total

    const val PAGES_START = 0.02
    const val PAGES_SHARE = 0.9
}

/** What a compress run wrote. */
data class PdfCompressOutcome(val pageCount: Int, val sizeBytes: Long, val imagesSeen: Int, val imagesReplaced: Int)

/** Estimated sizes of the three presets ([presetBytes] in [PdfCompressPreset] order). */
data class PdfCompressEstimate(val sourceBytes: Long, val presetBytes: List<Long>, val sampled: Boolean)

object PdfCompressCore {
    /** In-memory scratch before PdfBox spills to [scratchDir] files. */
    private const val MAIN_MEMORY_BYTES = 32L * 1024 * 1024

    /**
     * Compresses [source] with [preset] into the new file [out]. [isCancelled] is polled per page
     * and per image; [progress] gets (fraction 0…1, pages done, pages total) on this thread.
     */
    fun compress(
        source: File,
        password: String?,
        preset: PdfCompressPreset,
        out: File,
        scratchDir: File?,
        isCancelled: () -> Boolean = { false },
        progress: (Double, Int, Int) -> Unit = { _, _, _ -> },
    ): PdfCompressOutcome {
        if (out.path.isEmpty() || out.exists()) throw PdfFailure.invalid("output exists")
        val parent = out.absoluteFile.parentFile
        if (parent == null || !parent.isDirectory) throw PdfFailure.invalid("no output directory")
        if (!source.isFile) throw PdfFailure.notFound("no such file")
        if (source.absoluteFile == out.absoluteFile) throw PdfFailure.invalid("output is the source")
        var created = false
        try {
            load(source, password, scratchDir).use { doc ->
                val total = doc.numberOfPages
                progress(0.0, 0, total)
                val shrunk = shrinkImages(doc, PdfCompressSettings.of(preset), isCancelled) { done ->
                    progress(PdfCompressRules.pageFraction(done, total), done, total)
                }
                if (isCancelled()) throw PdfFailure.cancelled()
                if (!out.createNewFile()) throw PdfFailure.invalid("output exists")
                created = true
                FileOutputStream(out).use { stream ->
                    if (shrunk.replaced == 0) {
                        // Nothing smaller to write: the source as it is (a text-only file never grows).
                        source.inputStream().use { it.copyTo(stream, COPY_BUFFER) }
                    } else {
                        // PDDocument.save closes its stream: keep the file open for the sync below.
                        write(doc, password, KeepOpen(stream).buffered(COPY_BUFFER))
                    }
                    stream.fd.sync()
                }
                if (isCancelled()) throw PdfFailure.cancelled()
                progress(1.0, total, total)
                return PdfCompressOutcome(total, out.length(), shrunk.seen, shrunk.replaced)
            }
        } catch (t: Throwable) {
            if (created) out.delete()
            throw t
        }
    }

    /**
     * The sizes each preset would give for [source]: exact for files of up to four pages (the same
     * write as a run), else from four evenly spread pages, scaled by their share of a plain write
     * of the same pages (as on Apple).
     */
    fun estimate(source: File, password: String?, scratchDir: File?, isCancelled: () -> Boolean = { false }): PdfCompressEstimate {
        if (!source.isFile) throw PdfFailure.notFound("no such file")
        val sourceBytes = source.length()
        val count = load(source, password, scratchDir).use { it.numberOfPages }
        val picks = PdfCompressRules.samplePages(count)
        val sampled = count > PdfCompressRules.FULL_ESTIMATE_PAGES
        var baseline = 0L
        if (sampled) {
            baseline = load(source, password, scratchDir).use { doc -> sampleOf(doc, picks).use { countingSave(it, null) } }
        }
        val sizes = PdfCompressPreset.values().map { preset ->
            if (isCancelled()) throw PdfFailure.cancelled()
            load(source, password, scratchDir).use { doc ->
                val settings = PdfCompressSettings.of(preset)
                if (sampled) {
                    sampleOf(doc, picks).use { sample ->
                        val shrunk = shrinkImages(sample, settings, isCancelled) {}
                        if (shrunk.replaced == 0) sourceBytes else PdfCompressRules.scaledEstimate(sourceBytes, countingSave(sample, null), baseline)
                    }
                } else {
                    val shrunk = shrinkImages(doc, settings, isCancelled) {}
                    if (shrunk.replaced == 0) sourceBytes else countingSave(doc, password)
                }
            }
        }
        return PdfCompressEstimate(sourceBytes, sizes, sampled)
    }

    // --- Internals -------------------------------------------------------------------------------

    private const val COPY_BUFFER = 64 * 1024

    private class Shrunk(val seen: Int, val replaced: Int)

    /** Opens [file] read-only; scratch buffers spill to [scratchDir] past 32 MB. */
    internal fun load(file: File, password: String?, scratchDir: File?): PDDocument {
        val memory = if (scratchDir != null && (scratchDir.isDirectory || scratchDir.mkdirs())) {
            MemoryUsageSetting.setupMixed(MAIN_MEMORY_BYTES).setTempDir(scratchDir)
        } else {
            MemoryUsageSetting.setupMainMemoryOnly()
        }
        try {
            return PDDocument.load(file, password ?: "", memory)
        } catch (e: InvalidPasswordException) {
            throw PdfFailure(PdfErrorCode.passwordRequired, "password required")
        } catch (e: IOException) {
            if (!file.exists()) throw PdfFailure.notFound("no such file")
            throw PdfFailure.damaged("not a readable PDF")
        } catch (e: RuntimeException) {
            throw PdfFailure.damaged("not a readable PDF")
        } catch (e: StackOverflowError) {
            throw PdfFailure.damaged("not a readable PDF")
        }
    }

    /** A new document holding [picks] of [doc]'s pages ([doc] must stay open until it is closed). */
    private fun sampleOf(doc: PDDocument, picks: List<Int>): PDDocument {
        val sample = PDDocument()
        try {
            for (i in picks) sample.importPage(doc.getPage(i))
        } catch (t: Throwable) {
            sample.close()
            throw PdfFailure.damaged("no pages to sample")
        }
        return sample
    }

    /** Re-encodes [doc]'s images in place; [onPage] gets the pages done after each page. */
    private fun shrinkImages(doc: PDDocument, settings: PdfCompressSettings, isCancelled: () -> Boolean, onPage: (Int) -> Unit): Shrunk {
        val done = IdentityHashMap<COSStream, Boolean>()
        val budget = PdfCompressRules.budgetPixels(Runtime.getRuntime().maxMemory())
        var seen = 0
        var replaced = 0
        for ((index, page) in doc.pages.withIndex()) {
            if (isCancelled()) throw PdfFailure.cancelled()
            val placed = placements(page)
            val images = LinkedHashMap<COSStream, PDImageXObject>()
            placed.images.forEach { (stream, image) -> images[stream] = image }
            collectImages(page.resources, images, 0)
            for ((stream, image) in images) {
                if (done.put(stream, true) != null) continue
                if (isCancelled()) throw PdfFailure.cancelled()
                seen++
                if (reencode(image, stream, settings, placed.dpi[stream], budget)) replaced++
            }
            onPage(index + 1)
        }
        return Shrunk(seen, replaced)
    }

    /** Every image XObject reachable from [resources] (through forms, a few levels deep). */
    private fun collectImages(resources: PDResources?, into: MutableMap<COSStream, PDImageXObject>, depth: Int) {
        if (resources == null || depth > 8) return
        val names = try {
            resources.xObjectNames.toList()
        } catch (e: Exception) {
            return
        }
        for (name in names) {
            val x = try {
                resources.getXObject(name)
            } catch (e: Exception) {
                null
            } catch (e: StackOverflowError) {
                null
            }
            when (x) {
                is PDImageXObject -> if (!into.containsKey(x.cosObject)) into[x.cosObject] = x
                is PDFormXObject -> collectImages(x.resources, into, depth + 1)
            }
        }
    }

    private class Placed(val images: Map<COSStream, PDImageXObject>, val dpi: Map<COSStream, Double>)

    /** The images drawn by [page]'s content (and its forms) with their lowest placed resolution. */
    private fun placements(page: PDPage): Placed {
        val finder = PlacementFinder()
        try {
            finder.processPage(page)
        } catch (e: Exception) {
            // Broken content: what was found so far still counts; the rest gets the fallback scale.
        } catch (e: StackOverflowError) {
            // Deeply nested forms: as above.
        }
        return Placed(finder.images, finder.dpi)
    }

    /** Walks a content stream tracking the CTM and records where each image is drawn. */
    private class PlacementFinder : PDFStreamEngine() {
        val images = IdentityHashMap<COSStream, PDImageXObject>()
        val dpi = IdentityHashMap<COSStream, Double>()

        init {
            addOperator(Concatenate())
            addOperator(DrawObject())
            addOperator(SetGraphicsStateParameters())
            addOperator(Save())
            addOperator(Restore())
            addOperator(SetMatrix())
        }

        override fun processOperator(operator: Operator, operands: MutableList<COSBase>) {
            if (operator.name == "Do") {
                val name = operands.firstOrNull() as? COSName
                val x = if (name == null) null else try {
                    resources?.getXObject(name)
                } catch (e: Exception) {
                    null
                }
                if (x is PDImageXObject) {
                    val ctm = graphicsState.currentTransformationMatrix
                    val d = PdfCompressRules.placedDpi(x.width, x.height, ctm.scalingFactorX.toDouble(), ctm.scalingFactorY.toDouble())
                    val stream = x.cosObject
                    images[stream] = x
                    if (d != null) dpi[stream] = minOf(d, dpi[stream] ?: Double.MAX_VALUE)
                    return
                }
            }
            super.processOperator(operator, operands)
        }
    }

    /** The facts of [image] for [PdfCompressRules.eligible]. */
    private fun factsOf(image: PDImageXObject, stream: COSStream): PdfImageFacts {
        val filters = when (val f = stream.getDictionaryObject(COSName.FILTER)) {
            is COSName -> listOf(f.name)
            is COSArray -> (0 until f.size()).map { (f.getObject(it) as? COSName)?.name ?: "?" }
            null -> emptyList()
            else -> listOf("?")
        }
        val usable = filters.all { it !in setOf("JPXDecode", "JBIG2Decode", "CCITTFaxDecode", "CCF", "?") }
        val components = if (!usable) null else try {
            when (val cs = image.colorSpace) {
                null -> null
                else -> when (cs.name) {
                    "DeviceGray", "CalGray", "DeviceRGB", "CalRGB" -> cs.numberOfComponents
                    "ICCBased" -> cs.numberOfComponents.takeIf { it == 1 || it == 3 }
                    else -> null // CMYK, Indexed, Separation, DeviceN, Lab, Pattern
                }
            }
        } catch (e: Exception) {
            null
        }
        val smaskInData = stream.getInt(COSName.getPDFName("SMaskInData"), 0)
        return PdfImageFacts(
            width = stream.getInt(COSName.WIDTH, 0),
            height = stream.getInt(COSName.HEIGHT, 0),
            bitsPerComponent = stream.getInt(COSName.BITS_PER_COMPONENT, -1),
            components = components,
            filters = filters,
            stencil = (stream.getDictionaryObject(COSName.IMAGE_MASK) as? COSBoolean)?.value == true,
            masked = stream.containsKey(COSName.MASK),
            softMasked = stream.containsKey(COSName.SMASK) || smaskInData != 0,
            hasDecode = stream.containsKey(COSName.DECODE),
            hasAlternates = stream.containsKey(COSName.getPDFName("Alternates")),
            external = stream.containsKey(COSName.F),
        )
    }

    /** Re-encodes one image in place when that pays; false when it is left alone. */
    private fun reencode(image: PDImageXObject, stream: COSStream, settings: PdfCompressSettings, dpi: Double?, budget: Long): Boolean {
        val facts = factsOf(image, stream)
        if (!PdfCompressRules.eligible(facts)) return false
        val (tw, th) = PdfCompressRules.targetSize(facts.width, facts.height, settings.scaleFor(dpi))
        val jpeg = try {
            encode(image, facts, tw, th, settings.quality, budget)
        } catch (e: OutOfMemoryError) {
            null // too big for this heap: left as it is
        } catch (e: Exception) {
            null // undecodable samples: left as it is
        } ?: return false
        if (!PdfCompressRules.worthReplacing(jpeg.size().toLong(), stream.length)) return false
        stream.createRawOutputStream().use { jpeg.writeTo(it) }
        stream.setItem(COSName.FILTER, COSName.DCT_DECODE)
        stream.removeItem(COSName.DECODE_PARMS)
        stream.removeItem(COSName.getPDFName("DP"))
        stream.setInt(COSName.WIDTH, tw)
        stream.setInt(COSName.HEIGHT, th)
        stream.setInt(COSName.BITS_PER_COMPONENT, 8)
        // PdfBox decodes through the colour space to sRGB and Android writes 3-channel JPEGs.
        stream.setItem(COSName.COLORSPACE, COSName.DEVICERGB)
        return true
    }

    /** [image] decoded, scaled to [tw] × [th] and encoded as a JPEG at [quality]. */
    private fun encode(image: PDImageXObject, facts: PdfImageFacts, tw: Int, th: Int, quality: Int, budget: Long): ByteArrayOutputStream? {
        val sub = PdfCompressRules.subsampling(facts.width, facts.height, budget)
        val decoded = if (sub > 1) image.getImage(Rect(0, 0, facts.width, facts.height), sub) else image.image
        decoded ?: return null
        val scaled = if (decoded.width != tw || decoded.height != th) Bitmap.createScaledBitmap(decoded, tw, th, true) else decoded
        try {
            val out = ByteArrayOutputStream(maxOf(4096, tw * th / 4))
            if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
            return out
        } finally {
            if (scaled !== decoded) scaled.recycle()
            decoded.recycle()
        }
    }

    /** Saves [doc] to [out], encrypted again when it was ([password]: what it was opened with). */
    private fun write(doc: PDDocument, password: String?, out: OutputStream) {
        if (doc.isEncrypted) protectLikeSource(doc, password)
        doc.save(out)
        out.flush()
    }

    /** The bytes [doc] would write (encrypted again when [password] is set or it was encrypted). */
    private fun countingSave(doc: PDDocument, password: String?): Long {
        val counter = CountingStream()
        write(doc, password, counter)
        return counter.count
    }

    private fun protectLikeSource(doc: PDDocument, password: String?) {
        val keyLength = if (doc.encryption?.length == 256) 256 else 128
        val pw = password.orEmpty()
        val policy = if (pw.isNotEmpty()) {
            StandardProtectionPolicy(pw, pw, AccessPermission())
        } else {
            // Opened with the empty user password: keep it and the owner's restrictions.
            StandardProtectionPolicy(UUID.randomUUID().toString(), "", AccessPermission(doc.currentAccessPermission.permissionBytes))
        }
        policy.encryptionKeyLength = keyLength
        doc.protect(policy)
    }

    /** Passes writes through to [target] but only flushes it on close. */
    private class KeepOpen(private val target: OutputStream) : OutputStream() {
        override fun write(b: Int) = target.write(b)

        override fun write(b: ByteArray, off: Int, len: Int) = target.write(b, off, len)

        override fun flush() = target.flush()

        override fun close() = target.flush()
    }

    private class CountingStream : OutputStream() {
        var count = 0L

        override fun write(b: Int) {
            count++
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            count += len
        }
    }
}
