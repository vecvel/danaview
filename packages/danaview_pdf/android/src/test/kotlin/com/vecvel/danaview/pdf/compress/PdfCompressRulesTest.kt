// OWNER: HOM-31A
//
// JVM tests of the pure compress rules (compress/PdfCompressCore.kt): preset settings and the
// scale each one gives, image eligibility (masks, CMYK, indexed, 1-bit, JPX / JBIG2 / CCITT stay),
// the 10 % saving rule, decode subsampling, placed resolution, estimate sampling and scaling,
// progress fractions, the preset mapping, the request checks that run before any PDF is opened,
// and the tools API without a compressor.

package com.vecvel.danaview.pdf.compress

import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.glue.PdfThreads
import com.vecvel.danaview.pdf.glue.PdfToolsHostApiImpl
import com.vecvel.danaview.pdf.pigeon.PdfCompressPresetMsg
import com.vecvel.danaview.pdf.pigeon.PdfCompressRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfPigeonError
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolResultMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PdfCompressRulesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val image = PdfImageFacts(
        width = 2250, height = 2700, bitsPerComponent = 8, components = 3, filters = listOf("FlateDecode"),
        stencil = false, masked = false, softMasked = false, hasDecode = false, hasAlternates = false, external = false,
    )

    @Test
    fun presetsFallInQualityAndResolution() {
        val (h, m, s) = PdfCompressPreset.values().map { PdfCompressSettings.of(it) }
        assertTrue(h.quality > m.quality && m.quality > s.quality)
        // A 300 dpi scan: High keeps it, Medium goes to 144 dpi, Small below that.
        assertEquals(1.0, h.scaleFor(300.0), 1e-9)
        assertEquals(0.48, m.scaleFor(300.0), 1e-9)
        assertEquals(0.48 * 0.67, s.scaleFor(300.0), 1e-9)
        // A 75 dpi image: Medium only re-encodes; Small still scales.
        assertEquals(1.0, m.scaleFor(75.0), 1e-9)
        assertEquals(0.67, s.scaleFor(75.0), 1e-9)
        // Unknown placement: the Apple fallback scales.
        assertEquals(1.0, h.scaleFor(null), 1e-9)
        assertEquals(0.75, m.scaleFor(null), 1e-9)
        assertEquals(0.5, s.scaleFor(null), 1e-9)
        assertEquals(0.5, s.scaleFor(Double.NaN), 1e-9)
        // Never below the floor, never up.
        assertEquals(PdfCompressSettings.MIN_SCALE, s.scaleFor(100_000.0), 1e-9)
        assertTrue(PdfCompressPreset.values().all { p -> PdfCompressSettings.of(p).scaleFor(10.0) <= 1.0 })
    }

    @Test
    fun onlyPlainEightBitGrayAndRgbImagesAreReencoded() {
        assertTrue(PdfCompressRules.eligible(image))
        assertTrue(PdfCompressRules.eligible(image.copy(components = 1, filters = listOf("DCTDecode"))))
        assertTrue(PdfCompressRules.eligible(image.copy(filters = emptyList())))
        assertTrue(PdfCompressRules.eligible(image.copy(filters = listOf("ASCII85Decode", "FlateDecode"))))
        assertFalse("CMYK", PdfCompressRules.eligible(image.copy(components = 4)))
        assertFalse("indexed / separation", PdfCompressRules.eligible(image.copy(components = null)))
        assertFalse("1-bit", PdfCompressRules.eligible(image.copy(bitsPerComponent = 1)))
        assertFalse("16-bit", PdfCompressRules.eligible(image.copy(bitsPerComponent = 16)))
        assertFalse("stencil", PdfCompressRules.eligible(image.copy(stencil = true)))
        assertFalse("mask", PdfCompressRules.eligible(image.copy(masked = true)))
        assertFalse("soft mask", PdfCompressRules.eligible(image.copy(softMasked = true)))
        assertFalse("decode array", PdfCompressRules.eligible(image.copy(hasDecode = true)))
        assertFalse("alternates", PdfCompressRules.eligible(image.copy(hasAlternates = true)))
        assertFalse("external", PdfCompressRules.eligible(image.copy(external = true)))
        assertFalse("tiny", PdfCompressRules.eligible(image.copy(width = 15)))
        for (f in listOf("JPXDecode", "JBIG2Decode", "CCITTFaxDecode")) {
            assertFalse(f, PdfCompressRules.eligible(image.copy(filters = listOf(f))))
        }
    }

    @Test
    fun sizesSavingsAndSubsampling() {
        assertEquals(Pair(1080, 1296), PdfCompressRules.targetSize(2250, 2700, 0.48))
        assertEquals(Pair(1, 1), PdfCompressRules.targetSize(10, 10, 0.01))
        assertTrue(PdfCompressRules.worthReplacing(90, 100))
        assertFalse(PdfCompressRules.worthReplacing(91, 100))
        assertFalse(PdfCompressRules.worthReplacing(0, 100))
        assertEquals(1, PdfCompressRules.subsampling(2250, 2700, 8_000_000))
        assertEquals(2, PdfCompressRules.subsampling(5100, 6600, 9_000_000)) // 600 dpi letter
        assertEquals(3, PdfCompressRules.subsampling(5100, 6600, 8_000_000))
        assertEquals(8_000_000L, PdfCompressRules.budgetPixels(192L * 1000 * 1000))
        assertEquals(1_000_000L, PdfCompressRules.budgetPixels(1L))
        assertEquals(40_000_000L, PdfCompressRules.budgetPixels(Long.MAX_VALUE))
    }

    @Test
    fun placedResolution() {
        // 2250 px over 540 pt (7.5 in) = 300 dpi; the lower axis wins.
        assertEquals(300.0, PdfCompressRules.placedDpi(2250, 2700, 540.0, 648.0)!!, 1e-9)
        assertEquals(150.0, PdfCompressRules.placedDpi(2250, 1350, 540.0, 648.0)!!, 1e-9)
        assertNull(PdfCompressRules.placedDpi(100, 100, 0.0, 10.0))
    }

    @Test
    fun estimateSamplingAndScaling() {
        assertEquals(listOf(0, 1, 2), PdfCompressRules.samplePages(3))
        assertEquals(listOf(0, 1, 2, 3), PdfCompressRules.samplePages(4))
        assertEquals(listOf(0, 2, 5, 8), PdfCompressRules.samplePages(9))
        assertEquals(listOf(0, 66, 132, 199), PdfCompressRules.samplePages(200))
        assertTrue(PdfCompressRules.samplePages(0).isEmpty())
        assertEquals(500L, PdfCompressRules.scaledEstimate(1000, 50, 100))
        assertEquals(1000L, PdfCompressRules.scaledEstimate(1000, 50, 0))
    }

    @Test
    fun progressFractionsRiseWithPages() {
        assertEquals(0.02, PdfCompressRules.pageFraction(0, 3), 1e-9)
        assertEquals(0.92, PdfCompressRules.pageFraction(3, 3), 1e-9)
        val fractions = (0..200).map { PdfCompressRules.pageFraction(it, 200) }
        assertEquals(fractions.sorted(), fractions)
        assertEquals(0.02, PdfCompressRules.pageFraction(5, 0), 1e-9)
    }

    @Test
    fun presetsMapFromPigeon() {
        assertEquals(PdfCompressPreset.HIGH, PdfCompressor.presetOf(PdfCompressPresetMsg.HIGH))
        assertEquals(PdfCompressPreset.MEDIUM, PdfCompressor.presetOf(PdfCompressPresetMsg.MEDIUM))
        assertEquals(PdfCompressPreset.SMALL, PdfCompressor.presetOf(PdfCompressPresetMsg.SMALL))
        assertEquals(listOf(PdfToolKindMsg.COMPRESS), PdfCompressor.supported)
    }

    private fun failure(block: () -> Unit): PdfFailure {
        try {
            block()
        } catch (f: PdfFailure) {
            return f
        }
        fail("expected a PdfFailure")
        throw AssertionError()
    }

    @Test
    fun badRequestsFailTypedBeforeOpeningAnything() {
        val source = tmp.newFile("in.pdf").apply { writeText("%PDF-1.4 not really") }
        val existing = tmp.newFile("exists.pdf").apply { writeText("keep") }
        fun run(out: File, src: File = source) = PdfCompressCore.compress(src, null, PdfCompressPreset.MEDIUM, out, null)

        assertEquals("invalidArgument", failure { run(existing) }.code.name)
        assertEquals("keep", existing.readText())
        assertEquals("invalidArgument", failure { run(File(tmp.root, "no/such/dir/out.pdf")) }.code.name)
        assertEquals("invalidArgument", failure { run(File("")) }.code.name)
        val out = File(tmp.root, "out.pdf")
        assertEquals("notFound", failure { run(out, File(tmp.root, "missing.pdf")) }.code.name)
        assertFalse(out.exists())
        assertEquals("notFound", failure { PdfCompressCore.estimate(File(tmp.root, "missing.pdf"), null, null) }.code.name)
    }

    @Test
    fun toolsApiWithoutCompressorAnswersNotSupported() {
        var result: Result<PdfToolResultMsg>? = null
        val threads = PdfThreads() // android.jar stubs (isReturnDefaultValues); compress never reaches it
        val tools = PdfToolsHostApiImpl(threads, {})
        tools.compress(
            PdfCompressRequestMsg("j1", PdfToolInputMsg("/x.pdf", null, false), PdfCompressPresetMsg.SMALL, "/y.pdf"),
        ) { result = it }
        assertEquals("notSupportedOnDevice", (result!!.exceptionOrNull() as PdfPigeonError).code)
        tools.cancel("j1") // no compressor, no job: ignored
        threads.shutdown()
    }
}
