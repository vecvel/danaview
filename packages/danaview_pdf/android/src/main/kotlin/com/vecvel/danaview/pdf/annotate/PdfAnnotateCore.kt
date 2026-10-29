// OWNER: HOM-29A
// EXTENDED: HOM-30A (burn-in of image stamps for sign: quarter-turned stamps fill their rect).
//
// The Flutter-free core of the annotate save on Android (HOM plan §8.5; ARCH v1.2 rule 27), on
// PdfBox-Android 2.0.27.0 (HOM-27). Semantics of darwin/Classes/Annotate/PdfAnnotateCore.swift
// (HOM-29), so both platforms answer the same requests the same way:
//
// - Real PDF annotations with appearance streams (/AP), so other apps show and edit them:
//   Highlight / Underline / StrikeOut with one quadrilateral per line, Ink with one /InkList path
//   per stroke and /BS /W, FreeText with /DA (Helvetica 14 pt in the colour) and a height fitted
//   to the text from the box's top edge, Text notes (24 pt icon). Colours are 0xAARRGGBB; an alpha
//   below 1 becomes the annotation's /CA.
// - Image stamps: a Stamp annotation whose appearance is the image (movable in other apps), or with
//   `burnIn` drawn into the page content (HOM-30's signatures). Burn-in draws the request's
//   annotations (their appearance streams) and stamps into the page with an appended content
//   stream (the page's own content wrapped in q/Q first), so text stays text; the page's boxes,
//   /Rotate and its own annotations are kept, and no new annotation is left.
// - Geometry is the Pigeon page space: points, origin at the crop box's bottom-left, unrotated
//   (the crop box origin is added here).
// - File rules as the page tools (tools/PdfPageToolsCore.kt): the source is opened read-only and
//   never written; only `outPath` (must not exist, its folder must) is written, once, at the end,
//   and deleted on cancel or failure; cancel is polled per page and around the write; progress
//   counts the pages touched plus the write. Encrypted in → encrypted out (PdfOutputEncryption).
// - Permissions: annotations need `canModifyAnnotations()`, burn-in also `canModify()`; otherwise
//   `unsupported`. Nothing here logs; messages are fixed strings (rule 30).

package com.vecvel.danaview.pdf.annotate

import android.graphics.Bitmap
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationRubberStamp
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDBorderStyleDictionary
import com.tom_roush.pdfbox.util.Matrix
import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import com.vecvel.danaview.pdf.tools.PdfOutputEncryption
import com.vecvel.danaview.pdf.tools.PdfPageToolsCore
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfToolSource
import com.vecvel.danaview.pdf.tools.PdfWrittenFile
import java.io.File
import java.io.IOException
import java.util.Calendar
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A rect in page space (points, origin bottom-left of the crop box, unrotated). */
data class PdfBox(val x: Double, val y: Double, val width: Double, val height: Double) {
    val right: Double get() = x + width
    val top: Double get() = y + height
    val isFinite: Boolean get() = x.isFinite() && y.isFinite() && width.isFinite() && height.isFinite()

    fun union(o: PdfBox): PdfBox {
        val l = min(x, o.x)
        val b = min(y, o.y)
        return PdfBox(l, b, max(right, o.right) - l, max(top, o.top) - b)
    }

    fun inset(d: Double): PdfBox = PdfBox(x + d, y + d, width - 2 * d, height - 2 * d)

    fun contains(px: Double, py: Double): Boolean = px >= x && px <= right && py >= y && py <= top
}

/** The kinds of the Pigeon `PdfAnnotationKindMsg`, in its order. */
enum class PdfAnnotationKind { HIGHLIGHT, UNDERLINE, STRIKE_OUT, INK, FREE_TEXT, NOTE }

/** One annotation to add; [strokes] are flat page-space points `[x0, y0, x1, y1, …]`. */
data class PdfAnnotationSpec(
    val kind: PdfAnnotationKind,
    val pageIndex: Int,
    val rects: List<PdfBox> = emptyList(),
    val strokes: List<DoubleArray> = emptyList(),
    val colorArgb: Long = 0xFF000000,
    val lineWidth: Double = 2.0,
    val text: String? = null,
)

/** An image filling [rect], turned [rotationDegrees] clockwise around its centre. */
data class PdfStampSpec(val pageIndex: Int, val rect: PdfBox, val imagePath: String, val rotationDegrees: Double = 0.0)

object PdfAnnotateCore {
    /** Text boxes use this font size (points), as on Apple. */
    const val FREE_TEXT_FONT_SIZE = 14.0

    /** Padding inside a text box (points). */
    const val FREE_TEXT_PADDING = 4.0

    /** The note icon's side (points). */
    const val NOTE_SIZE = 24.0

    /** Limits of one ink annotation (Apple's). */
    const val MAX_STROKE_POINTS = 20_000
    const val MAX_STROKES = 500

    /** Stamp images are embedded at most this many pixels on their longer side (Apple: 2048). */
    const val STAMP_MAX_PIXELS = 2048

    private val font by lazy { PDType1Font.HELVETICA }

    // ---------------------------------------------------------------------------------------------
    // Validation

    /** Fails with `invalidArgument` unless [spec] is a well-formed annotation of a [pageCount]-page document. */
    fun validate(spec: PdfAnnotationSpec, pageCount: Int) {
        if (spec.pageIndex < 0 || spec.pageIndex >= pageCount) throw PdfFailure.invalid("page out of range")
        if (!spec.lineWidth.isFinite() || spec.lineWidth < 0 || spec.lineWidth > 200) throw PdfFailure.invalid("bad line width")
        if (!spec.rects.all { it.isFinite && it.width >= 0 && it.height >= 0 }) throw PdfFailure.invalid("bad rect")
        when (spec.kind) {
            PdfAnnotationKind.HIGHLIGHT, PdfAnnotationKind.UNDERLINE, PdfAnnotationKind.STRIKE_OUT ->
                if (spec.rects.isEmpty() || !spec.rects.all { it.width > 0 && it.height > 0 }) throw PdfFailure.invalid("markup needs line rects")
            PdfAnnotationKind.INK -> {
                val ok = spec.strokes.isNotEmpty() && spec.strokes.size <= MAX_STROKES && spec.strokes.all { s ->
                    s.size >= 2 && s.size % 2 == 0 && s.size / 2 <= MAX_STROKE_POINTS && s.all { it.isFinite() }
                }
                if (!ok) throw PdfFailure.invalid("ink needs strokes")
            }
            PdfAnnotationKind.FREE_TEXT, PdfAnnotationKind.NOTE -> {
                if (spec.rects.isEmpty()) throw PdfFailure.invalid("text needs a box")
                if (spec.text.isNullOrBlank()) throw PdfFailure.invalid("text is empty")
            }
        }
    }

    /** Fails with `invalidArgument` unless [stamp] is a well-formed stamp of a [pageCount]-page document. */
    fun validate(stamp: PdfStampSpec, pageCount: Int) {
        if (stamp.pageIndex < 0 || stamp.pageIndex >= pageCount) throw PdfFailure.invalid("page out of range")
        val r = stamp.rect
        if (!r.isFinite || r.width <= 0 || r.height <= 0 || !stamp.rotationDegrees.isFinite()) throw PdfFailure.invalid("bad stamp rect")
        if (stamp.imagePath.isEmpty()) throw PdfFailure.invalid("no stamp image")
    }

    // ---------------------------------------------------------------------------------------------
    // Saving

    /**
     * Writes [input] with [annotations] and [stamps] added into the new file [outPath]; with [burnIn]
     * they are drawn into the page content instead (the pages' own annotations stay annotations).
     */
    fun annotate(
        input: PdfToolSource,
        annotations: List<PdfAnnotationSpec>,
        stamps: List<PdfStampSpec> = emptyList(),
        burnIn: Boolean = false,
        outPath: String,
        control: PdfToolControl,
    ): PdfWrittenFile {
        if (input.isImage) throw PdfFailure.invalid("annotate needs a PDF")
        PdfPageToolsCore.checkNewFile(outPath, listOf(input.path))
        val file = File(input.path)
        if (!file.isFile) throw PdfFailure.notFound("no such file")
        val doc = PdfBoxSupport.load(file, input.password)
        try {
            val count = doc.numberOfPages
            if (count <= 0) throw PdfFailure.damaged("document has no pages")
            val permission = doc.currentAccessPermission
            if (!permission.canModifyAnnotations()) throw PdfFailure(PdfErrorCode.unsupported, "document forbids annotations")
            if (burnIn && !permission.canModify()) throw PdfFailure(PdfErrorCode.unsupported, "document forbids changes")
            annotations.forEach { validate(it, count) }
            stamps.forEach { validate(it, count) }
            PdfPageToolsCore.checkCancelled(control)
            val images = HashMap<String, PDImageXObject>()
            for (stamp in stamps) {
                if (!images.containsKey(stamp.imagePath)) images[stamp.imagePath] = loadImage(doc, stamp.imagePath)
            }
            val encryption = PdfOutputEncryption.of(doc, input.password)
            val pages = (annotations.map { it.pageIndex } + stamps.map { it.pageIndex }).distinct().sorted()
            val total = pages.size + 1
            return PdfPageToolsCore.writingNewFiles { outputs ->
                control.progress(0, total)
                for ((done, index) in pages.withIndex()) {
                    PdfPageToolsCore.checkCancelled(control)
                    val page = doc.getPage(index)
                    val added = ArrayList<PDAnnotation>()
                    for (spec in annotations) if (spec.pageIndex == index) added += makeAnnotation(doc, spec, page)
                    if (burnIn) {
                        burn(doc, page, added, stamps.filter { it.pageIndex == index }, images)
                    } else {
                        for (stamp in stamps) if (stamp.pageIndex == index) added += makeStamp(doc, stamp, images.getValue(stamp.imagePath), page)
                        val list = page.annotations
                        for (a in added) {
                            a.page = page
                            list += a
                        }
                        page.annotations = list
                    }
                    control.progress(done + 1, total)
                }
                val written = PdfPageToolsCore.write(doc, outPath, control, encryption, outputs)
                control.progress(total, total)
                written
            }
        } finally {
            try {
                doc.close()
            } catch (_: IOException) {
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Annotations

    /** The PdfBox annotation of [spec] on [page], with its appearance stream. */
    fun makeAnnotation(doc: PDDocument, spec: PdfAnnotationSpec, page: PDPage): PDAnnotation {
        val crop = page.cropBox
        val ox = crop.lowerLeftX.toDouble()
        val oy = crop.lowerLeftY.toDouble()
        val alpha = ((spec.colorArgb ushr 24) and 0xFF) / 255f
        val color = color(spec.colorArgb)
        val annotation: PDAnnotation = when (spec.kind) {
            PdfAnnotationKind.HIGHLIGHT, PdfAnnotationKind.UNDERLINE, PdfAnnotationKind.STRIKE_OUT -> {
                val rects = spec.rects.map { PdfBox(it.x + ox, it.y + oy, it.width, it.height) }
                val bounds = rects.reduce { a, b -> a.union(b) }
                PDAnnotationTextMarkup(subtype(spec.kind)).apply {
                    rectangle = pdRect(bounds)
                    quadPoints = quadPoints(rects)
                    this.color = color
                    if (alpha < 1f) constantOpacity = alpha
                }
            }
            PdfAnnotationKind.INK -> {
                val pad = max(spec.lineWidth, 1.0)
                val strokes = spec.strokes.map { s ->
                    // A single point becomes a short segment, so it draws as a dot.
                    val pts = if (s.size == 2) doubleArrayOf(s[0], s[1], s[0] + 0.01, s[1]) else s
                    FloatArray(pts.size) { i -> (pts[i] + if (i % 2 == 0) ox else oy).toFloat() }
                }
                var l = Double.MAX_VALUE
                var b = Double.MAX_VALUE
                var r = -Double.MAX_VALUE
                var t = -Double.MAX_VALUE
                for (s in strokes) for (i in s.indices step 2) {
                    l = min(l, s[i].toDouble()); r = max(r, s[i].toDouble())
                    b = min(b, s[i + 1].toDouble()); t = max(t, s[i + 1].toDouble())
                }
                PDAnnotationMarkup().apply {
                    cosObject.setName(COSName.SUBTYPE, PDAnnotationMarkup.SUB_TYPE_INK)
                    rectangle = pdRect(PdfBox(l - pad, b - pad, r - l + 2 * pad, t - b + 2 * pad))
                    inkList = strokes.toTypedArray()
                    borderStyle = PDBorderStyleDictionary().apply { width = spec.lineWidth.toFloat() }
                    this.color = color
                    if (alpha < 1f) constantOpacity = alpha
                }
            }
            PdfAnnotationKind.FREE_TEXT -> {
                val box = freeTextBounds(spec.text.orEmpty(), spec.rects[0], crop.width.toDouble(), crop.height.toDouble())
                PDAnnotationMarkup().apply {
                    cosObject.setName(COSName.SUBTYPE, PDAnnotationMarkup.SUB_TYPE_FREETEXT)
                    rectangle = pdRect(PdfBox(box.x + ox, box.y + oy, box.width, box.height))
                    contents = spec.text
                    defaultAppearance = defaultAppearance(spec.colorArgb)
                    // Left aligned, no border, no fill.
                    cosObject.setInt(COSName.Q, 0)
                    borderStyle = PDBorderStyleDictionary().apply { width = 0f }
                    if (alpha < 1f) constantOpacity = alpha
                }
            }
            PdfAnnotationKind.NOTE -> {
                val r = spec.rects[0]
                PDAnnotationText().apply {
                    rectangle = pdRect(PdfBox(r.x + ox, r.y + oy, NOTE_SIZE, NOTE_SIZE))
                    contents = spec.text
                    name = PDAnnotationText.NAME_NOTE
                    this.color = color
                }
            }
        }
        annotation.isPrinted = true
        annotation.setModifiedDate(Calendar.getInstance())
        annotation.page = page
        (annotation as PDAnnotationMarkup).constructAppearances(doc)
        if (spec.kind == PdfAnnotationKind.NOTE) {
            // PdfBox's note appearance shrinks the rect to its icon (18 x 20); keep Apple's 24 pt
            // box (the appearance is scaled into it).
            val r = spec.rects[0]
            annotation.rectangle = pdRect(PdfBox(r.x + ox, r.y + oy, NOTE_SIZE, NOTE_SIZE))
        }
        return annotation
    }

    /** A Stamp annotation showing [image] in [spec]'s rect on [page] (its appearance is the image). */
    fun makeStamp(doc: PDDocument, spec: PdfStampSpec, image: PDImageXObject, page: PDPage): PDAnnotationRubberStamp {
        val crop = page.cropBox
        val r = PdfBox(spec.rect.x + crop.lowerLeftX, spec.rect.y + crop.lowerLeftY, spec.rect.width, spec.rect.height)
        val appearance = PDAppearanceStream(doc).apply {
            bBox = PDRectangle(r.width.toFloat(), r.height.toFloat())
            resources = PDResources()
        }
        PDPageContentStream(doc, appearance).use { cs ->
            drawImage(cs, image, PdfBox(0.0, 0.0, r.width, r.height), spec.rotationDegrees)
        }
        return PDAnnotationRubberStamp().apply {
            rectangle = pdRect(r)
            this.appearance = PDAppearanceDictionary().apply { setNormalAppearance(appearance) }
            isPrinted = true
            setModifiedDate(Calendar.getInstance())
            this.page = page
        }
    }

    /**
     * Draws [annotations] (their normal appearances) and [stamps] into [page]'s content: a new
     * content stream appended after the page's own, which is wrapped in q / Q first.
     */
    fun burn(doc: PDDocument, page: PDPage, annotations: List<PDAnnotation>, stamps: List<PdfStampSpec>, images: Map<String, PDImageXObject>) {
        if (annotations.isEmpty() && stamps.isEmpty()) return
        val crop = page.cropBox
        PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
            for (a in annotations) {
                val appearance = a.normalAppearanceStream ?: continue
                val matrix = appearanceMatrix(appearance, a.rectangle) ?: continue
                cs.saveGraphicsState()
                cs.transform(matrix)
                cs.drawForm(appearance)
                cs.restoreGraphicsState()
            }
            for (stamp in stamps) {
                val r = PdfBox(stamp.rect.x + crop.lowerLeftX, stamp.rect.y + crop.lowerLeftY, stamp.rect.width, stamp.rect.height)
                drawImage(cs, images.getValue(stamp.imagePath), r, stamp.rotationDegrees)
            }
        }
    }

    /**
     * The matrix that places an appearance stream in [rect] (PDF 32000-1 §12.5.5): its bbox,
     * transformed by its /Matrix, is mapped onto the annotation's rect. Null when either is empty.
     */
    internal fun appearanceMatrix(appearance: PDAppearanceStream, rect: PDRectangle?): Matrix? {
        val bbox = appearance.bBox ?: return null
        if (rect == null || rect.width <= 0 || rect.height <= 0) return null
        val m = appearance.matrix
        val corners = listOf(
            m.transformPoint(bbox.lowerLeftX, bbox.lowerLeftY),
            m.transformPoint(bbox.upperRightX, bbox.lowerLeftY),
            m.transformPoint(bbox.lowerLeftX, bbox.upperRightY),
            m.transformPoint(bbox.upperRightX, bbox.upperRightY),
        )
        val minX = corners.minOf { it.x }
        val minY = corners.minOf { it.y }
        val w = corners.maxOf { it.x } - minX
        val h = corners.maxOf { it.y } - minY
        if (w <= 0f || h <= 0f) return null
        val a = Matrix(rect.width / w, 0f, 0f, rect.height / h, rect.lowerLeftX - minX * rect.width / w, rect.lowerLeftY - minY * rect.height / h)
        // `Do` applies the form's own /Matrix itself; the content stream adds only the bbox-to-rect map.
        return a
    }

    /**
     * Draws [image] filling [rect] (PDF user space), turned [rotation] degrees clockwise around its
     * centre; a quarter turn (90 / 270) swaps the image's sides first, so it still fills [rect].
     */
    fun drawImage(cs: PDPageContentStream, image: PDImageXObject, rect: PdfBox, rotation: Double) {
        cs.saveGraphicsState()
        cs.transform(Matrix.getTranslateInstance((rect.x + rect.width / 2).toFloat(), (rect.y + rect.height / 2).toFloat()))
        if (rotation != 0.0) cs.transform(Matrix.getRotateInstance(Math.toRadians(-rotation), 0f, 0f))
        val swap = isQuarterTurn(rotation)
        val w = if (swap) rect.height else rect.width
        val h = if (swap) rect.width else rect.height
        cs.drawImage(image, (-w / 2).toFloat(), (-h / 2).toFloat(), w.toFloat(), h.toFloat())
        cs.restoreGraphicsState()
    }

    /** True for 90° and 270° (any multiple of 90 that is an odd number of quarter turns). */
    fun isQuarterTurn(rotation: Double): Boolean {
        val quarter = (rotation / 90).roundToInt()
        return abs(rotation - quarter * 90.0) < 0.01 && quarter % 2 != 0
    }

    /**
     * The image of a stamp (PNG with transparency kept, JPEG; orientation applied, at most
     * [STAMP_MAX_PIXELS] on its longer side): `notFound` when missing, `invalidArgument` when unreadable.
     */
    fun loadImage(doc: PDDocument, path: String): PDImageXObject {
        if (!File(path).isFile) throw PdfFailure.notFound("no such image")
        val decoded = try {
            PdfPageToolsCore.decodeImage(path)
        } catch (f: PdfFailure) {
            if (f.code == PdfErrorCode.notFound) throw f
            throw PdfFailure.invalid("not a readable image")
        }
        var bitmap = decoded
        val longSide = max(bitmap.width, bitmap.height)
        if (longSide > STAMP_MAX_PIXELS) {
            val s = STAMP_MAX_PIXELS.toDouble() / longSide
            val scaled = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * s).roundToInt()), max(1, (bitmap.height * s).roundToInt()), true)
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }
        try {
            return if (bitmap.hasAlpha()) LosslessFactory.createFromImage(doc, bitmap) else JPEGFactory.createFromImage(doc, bitmap, 0.9f)
        } finally {
            bitmap.recycle()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Geometry and text

    /**
     * The box of a text annotation in page space: [box]'s top edge and width (at least 40 points, at
     * most what fits on a [pageW] × [pageH] crop box), the height fitted to [text] at
     * [FREE_TEXT_FONT_SIZE] Helvetica.
     */
    fun freeTextBounds(text: String, box: PdfBox, pageW: Double, pageH: Double): PdfBox {
        val left = min(max(box.x, 0.0), max(0.0, pageW - 40))
        val width = min(max(box.width, 40.0), pageW - left)
        val top = min(max(box.top, FREE_TEXT_FONT_SIZE * 1.5), pageH)
        val inner = max(width - 2 * FREE_TEXT_PADDING, 1.0)
        val lines = wrap(text, inner).size.coerceAtLeast(1)
        val height = ceil(lines * FREE_TEXT_FONT_SIZE * LINE_HEIGHT * 1.25) + 2 * FREE_TEXT_PADDING
        return PdfBox(left, top - height, width, height)
    }

    /** Helvetica's line height as a multiple of the font size (ascent + descent + gap). */
    private const val LINE_HEIGHT = 1.15

    /** [text] broken into lines no wider than [width] points at [FREE_TEXT_FONT_SIZE] Helvetica (words kept whole when they fit). */
    fun wrap(text: String, width: Double): List<String> {
        val out = ArrayList<String>()
        for (paragraph in text.split('\n')) {
            var line = StringBuilder()
            for (word in paragraph.split(' ')) {
                val candidate = if (line.isEmpty()) word else "$line $word"
                if (line.isEmpty() || textWidth(candidate) <= width) {
                    line = StringBuilder(candidate)
                } else {
                    out += line.toString()
                    line = StringBuilder(word)
                }
                // A word longer than the line is broken by characters.
                while (textWidth(line.toString()) > width && line.length > 1) {
                    var cut = line.length - 1
                    while (cut > 1 && textWidth(line.substring(0, cut)) > width) cut--
                    out += line.substring(0, cut)
                    line = StringBuilder(line.substring(cut))
                }
            }
            out += line.toString()
        }
        return out
    }

    /** Width of [s] in points at [FREE_TEXT_FONT_SIZE] Helvetica (characters Helvetica lacks count as an "n"). */
    fun textWidth(s: String): Double {
        var units = 0.0
        for (ch in s) {
            units += try {
                font.getStringWidth(ch.toString()).toDouble()
            } catch (e: Exception) {
                556.0
            }
        }
        return units / 1000.0 * FREE_TEXT_FONT_SIZE
    }

    /** Quadrilateral points of [rects] in PDF user space: top-left, top-right, bottom-left, bottom-right each. */
    fun quadPoints(rects: List<PdfBox>): FloatArray {
        val out = FloatArray(rects.size * 8)
        for ((i, r) in rects.withIndex()) {
            val v = floatArrayOf(r.x.toFloat(), r.top.toFloat(), r.right.toFloat(), r.top.toFloat(), r.x.toFloat(), r.y.toFloat(), r.right.toFloat(), r.y.toFloat())
            v.copyInto(out, i * 8)
        }
        return out
    }

    /** `/Helv 14 Tf r g b rg` for [argb]. */
    fun defaultAppearance(argb: Long): String {
        val c = rgb(argb)
        return String.format(java.util.Locale.ROOT, "/Helv %d Tf %.3f %.3f %.3f rg", FREE_TEXT_FONT_SIZE.toInt(), c[0], c[1], c[2])
    }

    fun subtype(kind: PdfAnnotationKind): String = when (kind) {
        PdfAnnotationKind.HIGHLIGHT -> PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT
        PdfAnnotationKind.UNDERLINE -> PDAnnotationTextMarkup.SUB_TYPE_UNDERLINE
        PdfAnnotationKind.STRIKE_OUT -> PDAnnotationTextMarkup.SUB_TYPE_STRIKEOUT
        PdfAnnotationKind.INK -> PDAnnotationMarkup.SUB_TYPE_INK
        PdfAnnotationKind.FREE_TEXT -> PDAnnotationMarkup.SUB_TYPE_FREETEXT
        PdfAnnotationKind.NOTE -> PDAnnotationText.SUB_TYPE
    }

    /** Red, green, blue of [argb] in 0…1. */
    fun rgb(argb: Long): FloatArray = floatArrayOf(
        ((argb ushr 16) and 0xFF) / 255f,
        ((argb ushr 8) and 0xFF) / 255f,
        (argb and 0xFF) / 255f,
    )

    private fun color(argb: Long) = PDColor(rgb(argb), PDDeviceRGB.INSTANCE)

    private fun pdRect(r: PdfBox) = PDRectangle(r.x.toFloat(), r.y.toFloat(), r.width.toFloat(), r.height.toFloat())
}
