// OWNER: HOM-30A
//
// JVM tests of the Android sign's pure rules (sign/PdfSigner.kt): an empty request and a malformed
// stamp fail with invalidArgument before any file is touched, and the capabilities list sign. The
// burn-in itself runs in the instrumented PdfSignTest.

package com.vecvel.danaview.pdf.sign

import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfRectMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignRequestMsg
import com.vecvel.danaview.pdf.pigeon.PdfSignatureStampMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolInputMsg
import com.vecvel.danaview.pdf.pigeon.PdfToolKindMsg
import com.vecvel.danaview.pdf.tools.PdfToolControl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class PdfSignRulesTest {
    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("hom30a").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private val control = object : PdfToolControl {
        override val isCancelled = false
        override fun progress(done: Int, total: Int) = Unit
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

    @Test
    fun badRequestsFailBeforeAnyFileIsTouched() {
        val input = File(dir, "in.pdf").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val out = File(dir, "out.pdf")
        fun request(stamps: List<PdfSignatureStampMsg>, outPath: String = out.path) =
            PdfSignRequestMsg("j", PdfToolInputMsg(input.path, null, false), stamps, outPath)
        assertEquals(PdfErrorCode.invalidArgument, code { PdfSigner.sign(request(emptyList()), control) })
        val stamp = PdfSignatureStampMsg(0, PdfRectMsg(0.0, 0.0, 10.0, 10.0), File(dir, "s.png").path, 0.0)
        assertEquals(PdfErrorCode.invalidArgument, code { PdfSigner.sign(request(listOf(stamp), input.path), control) })
        assertEquals(PdfErrorCode.notFound, code { PdfSigner.sign(request(listOf(stamp), File(dir, "no/out.pdf").path), control) })
        assertEquals(setOf("in.pdf"), dir.list()!!.toSet())
    }

    @Test
    fun capabilitiesListSign() {
        assertEquals(listOf(PdfToolKindMsg.SIGN), PdfSigner.supported)
        assertEquals("HOM-30A", PdfSigner.OWNER)
    }
}
