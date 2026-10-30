// OWNER: HOM-29A
//
// JVM tests of the annotate save's pure rules (annotate/PdfAnnotateCore.kt, annotate/PdfAnnotator.kt):
// request validation (the Apple core's rules), the Pigeon mapping of annotations, stamps and session
// items, quadrilateral order, the /DA string, quarter turns, the preview bounds of each kind,
// bad requests failing before any file is touched, and the capabilities. PdfBox itself
// (the written annotations, burn-in, encryption, cancel) runs in the instrumented PdfAnnotateTest.

package com.vecvel.danaview.pdf.annotate

import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfAnnotateItemMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotationKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfAnnotationMsg
import com.vecvel.danaview.pdf.pigeon.PdfInkStrokeMsg
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignatureStampMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.tools.PdfToolControl
import com.vecvel.danaview.pdf.tools.PdfToolSource
import com.vecvel.danaview.pdf.viewer.PageGeometry
import com.vecvel.danaview.pdf.viewer.PdfAnnotatePreview
import com.vecvel.danaview.pdf.viewer.PreviewItem
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class PdfAnnotateRulesTest {
    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("hom29a").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun code(block: () -> Unit): PdfErrorCode {
        try {
            block()
        } catch (f: PdfFailure) {
            return f.code
        }
        fail("expected a PdfFailure")
        throw IllegalStateException()
    }

    private val control = object : PdfToolControl {
        override val isCancelled = false
        override fun progress(done: Int, total: Int) = Unit
    }

    private val line = PdfBox(10.0, 20.0, 100.0, 12.0)

    @Test
    fun annotationsAreValidatedLikeApple() {
        val ok = listOf(
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0, rects = listOf(line)),
            PdfAnnotationSpec(PdfAnnotationKind.UNDERLINE, 1, rects = listOf(line, line)),
            PdfAnnotationSpec(PdfAnnotationKind.STRIKE_OUT, 0, rects = listOf(line)),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(1.0, 2.0), doubleArrayOf(1.0, 2.0, 3.0, 4.0))),
            PdfAnnotationSpec(PdfAnnotationKind.FREE_TEXT, 0, rects = listOf(PdfBox(1.0, 1.0, 0.0, 0.0)), text = "Hi"),
            PdfAnnotationSpec(PdfAnnotationKind.NOTE, 0, rects = listOf(line), text = "Note"),
        )
        ok.forEach { PdfAnnotateCore.validate(it, 2) }
        val bad = listOf(
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 2, rects = listOf(line)),
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, -1, rects = listOf(line)),
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0),
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0, rects = listOf(PdfBox(0.0, 0.0, 0.0, 5.0))),
            PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0, rects = listOf(PdfBox(Double.NaN, 0.0, 5.0, 5.0))),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf())),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(1.0, 2.0, 3.0))),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(1.0, Double.POSITIVE_INFINITY))),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = List(PdfAnnotateCore.MAX_STROKES + 1) { doubleArrayOf(1.0, 1.0) }),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(1.0, 1.0)), lineWidth = 201.0),
            PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(1.0, 1.0)), lineWidth = -1.0),
            PdfAnnotationSpec(PdfAnnotationKind.FREE_TEXT, 0, rects = listOf(line), text = "  \n"),
            PdfAnnotationSpec(PdfAnnotationKind.FREE_TEXT, 0, text = "x"),
            PdfAnnotationSpec(PdfAnnotationKind.NOTE, 0, rects = listOf(line)),
        )
        for (spec in bad) assertEquals(spec.toString(), PdfErrorCode.invalidArgument, code { PdfAnnotateCore.validate(spec, 2) })
    }

    @Test
    fun stampsAreValidated() {
        PdfAnnotateCore.validate(PdfStampSpec(0, line, "/x.png", 90.0), 1)
        for (s in listOf(
            PdfStampSpec(1, line, "/x.png"),
            PdfStampSpec(0, PdfBox(0.0, 0.0, 0.0, 10.0), "/x.png"),
            PdfStampSpec(0, line, "/x.png", Double.NaN),
            PdfStampSpec(0, line, ""),
        )) {
            assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotateCore.validate(s, 1) })
        }
    }

    @Test
    fun badRequestsFailBeforeAnyFileIsTouched() {
        val input = File(dir, "in.pdf").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val existing = File(dir, "out.pdf").apply { writeText("keep") }
        val src = PdfToolSource(input.path)
        assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotateCore.annotate(src, emptyList(), outPath = existing.path, control = control) })
        assertEquals("keep", existing.readText())
        assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotateCore.annotate(src, emptyList(), outPath = input.path, control = control) })
        assertEquals(PdfErrorCode.notFound, code { PdfAnnotateCore.annotate(src, emptyList(), outPath = File(dir, "no/out.pdf").path, control = control) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotateCore.annotate(PdfToolSource(input.path, isImage = true), emptyList(), outPath = File(dir, "a.pdf").path, control = control) })
        assertEquals(PdfErrorCode.notFound, code { PdfAnnotateCore.annotate(PdfToolSource(File(dir, "missing.pdf").path), emptyList(), outPath = File(dir, "b.pdf").path, control = control) })
        assertEquals(setOf("in.pdf", "out.pdf"), dir.list()!!.toSet())
        assertArrayEquals(byteArrayOf(1, 2, 3), input.readBytes())
    }

    @Test
    fun pigeonMessagesMapToSpecs() {
        val msg = PdfAnnotationMsg(
            kind = PdfAnnotationKindMsg.INK,
            pageIndex = 3,
            rects = listOf(PdfRectMsg(1.0, 2.0, 3.0, 4.0)),
            strokes = listOf(PdfInkStrokeMsg(listOf(1.0, 2.0, 3.0, 4.0))),
            colorArgb = 0xFF2040A0,
            lineWidth = 3.0,
            text = null,
        )
        val spec = PdfAnnotator.spec(msg)
        assertEquals(PdfAnnotationKind.INK, spec.kind)
        assertEquals(3, spec.pageIndex)
        assertEquals(listOf(PdfBox(1.0, 2.0, 3.0, 4.0)), spec.rects)
        assertArrayEquals(doubleArrayOf(1.0, 2.0, 3.0, 4.0), spec.strokes[0], 0.0)
        assertEquals(0xFF2040A0, spec.colorArgb)
        // Every kind keeps its place in the Pigeon enum.
        for (k in PdfAnnotationKindMsg.entries) assertEquals(k.name.replace("_", ""), PdfAnnotationKind.entries[k.raw].name.replace("_", ""))
        val stamp = PdfAnnotator.stamp(PdfSignatureStampMsg(1, PdfRectMsg(5.0, 6.0, 7.0, 8.0), "/s.png", 270.0))
        assertEquals(PdfStampSpec(1, PdfBox(5.0, 6.0, 7.0, 8.0), "/s.png", 270.0), stamp)
        val item = PdfAnnotator.item(PdfAnnotateItemMsg("a", stamp = PdfSignatureStampMsg(0, PdfRectMsg(0.0, 0.0, 1.0, 1.0), "/s.png", 0.0)))
        assertEquals("a", item.id)
        assertNull(item.annotation)
        assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotator.item(PdfAnnotateItemMsg("b")) })
        assertEquals(PdfErrorCode.invalidArgument, code { PdfAnnotator.item(PdfAnnotateItemMsg("c", msg, PdfSignatureStampMsg(0, PdfRectMsg(0.0, 0.0, 1.0, 1.0), "/s.png", 0.0))) })
    }

    @Test
    fun quadPointsRunTopLeftTopRightBottomLeftBottomRight() {
        val q = PdfAnnotateCore.quadPoints(listOf(PdfBox(10.0, 20.0, 30.0, 5.0), PdfBox(0.0, 0.0, 1.0, 1.0)))
        assertArrayEquals(floatArrayOf(10f, 25f, 40f, 25f, 10f, 20f, 40f, 20f, 0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f), q, 0f)
    }

    @Test
    fun defaultAppearanceIsHelvetica14InTheColour() {
        assertEquals("/Helv 14 Tf 1.000 0.000 0.502 rg", PdfAnnotateCore.defaultAppearance(0xFFFF0080))
    }

    @Test
    fun quarterTurnsSwapSides() {
        assertTrue(PdfAnnotateCore.isQuarterTurn(90.0))
        assertTrue(PdfAnnotateCore.isQuarterTurn(270.0))
        assertTrue(PdfAnnotateCore.isQuarterTurn(-90.0))
        assertFalse(PdfAnnotateCore.isQuarterTurn(0.0))
        assertFalse(PdfAnnotateCore.isQuarterTurn(180.0))
        assertFalse(PdfAnnotateCore.isQuarterTurn(45.0))
        assertFalse(PdfAnnotateCore.isQuarterTurn(90.5))
    }

    @Test
    fun previewBoundsCoverWhatIsDrawn() {
        val page = PageGeometry(612.0, 792.0, 0)
        val ink = PreviewItem("i", PdfAnnotationSpec(PdfAnnotationKind.INK, 0, strokes = listOf(doubleArrayOf(10.0, 10.0, 20.0, 30.0)), lineWidth = 4.0), null)
        assertEquals(PdfBox(8.0, 8.0, 14.0, 24.0), PdfAnnotatePreview.boundsOf(ink, page))
        val note = PreviewItem("n", PdfAnnotationSpec(PdfAnnotationKind.NOTE, 0, rects = listOf(PdfBox(5.0, 6.0, 1.0, 1.0)), text = "x"), null)
        assertEquals(PdfBox(5.0, 6.0, 24.0, 24.0), PdfAnnotatePreview.boundsOf(note, page))
        val markup = PreviewItem("m", PdfAnnotationSpec(PdfAnnotationKind.HIGHLIGHT, 0, rects = listOf(PdfBox(0.0, 0.0, 10.0, 10.0), PdfBox(5.0, 20.0, 10.0, 10.0))), null)
        assertEquals(PdfBox(0.0, 0.0, 15.0, 30.0), PdfAnnotatePreview.boundsOf(markup, page))
        val stamp = PreviewItem("s", null, PdfStampSpec(0, line, "/x.png"))
        assertEquals(line, PdfAnnotatePreview.boundsOf(stamp, page))
    }

    @Test
    fun capabilitiesListAnnotate() {
        assertEquals(listOf(PdfToolKindMsg.ANNOTATE), PdfAnnotator.supported)
        assertEquals("HOM-29A", PdfAnnotator.OWNER)
    }
}
