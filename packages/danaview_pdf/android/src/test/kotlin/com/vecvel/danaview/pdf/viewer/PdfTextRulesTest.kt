// OWNER: HOM-25
//
// JVM tests of the pure text rules (text/TextSearch.kt), the outline walk (viewer/PdfFacts.kt) and
// the error mapping (glue/PdfErrors.kt). They live with the viewer tests (HOM-25's test package).

package com.vecvel.danaview.pdf.viewer

import com.vecvel.danaview.pdf.glue.PdfErrorCode
import com.vecvel.danaview.pdf.glue.PdfErrors
import com.vecvel.danaview.pdf.glue.PdfFailure
import com.vecvel.danaview.pdf.pigeon.PdfPigeonError
import com.vecvel.danaview.pdf.text.FoldedText
import com.vecvel.danaview.pdf.text.LineEnds
import com.vecvel.danaview.pdf.text.TextBudget
import com.vecvel.danaview.pdf.text.TextQuery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class PdfTextRulesTest {
    // ---- search ----

    @Test
    fun caseInsensitiveSearchFoldsCaseDiacriticsAndWidth() {
        val text = "Café CAFE cafe ＣＡＦＥ"
        val hits = TextQuery.of("cafe", caseSensitive = false).matches(3, text, 10)
        assertEquals(listOf(0, 5, 10, 15), hits.map { it.start })
        assertTrue(hits.all { it.length == 4 && it.pageIndex == 3 })
        assertEquals("Café", text.substring(hits[0].start, hits[0].start + hits[0].length))
        assertEquals("ＣＡＦＥ", text.substring(hits[3].start, hits[3].start + hits[3].length))
    }

    @Test
    fun decomposedAccentsMapBackToTheWholeCharacter() {
        // "e" + combining acute (2 units) is one folded "e".
        val text = "résumé resume"
        val hits = TextQuery.of("RESUME", caseSensitive = false).matches(0, text, 10)
        assertEquals(2, hits.size)
        assertEquals(0, hits[0].start)
        assertEquals(8, hits[0].length)
        assertEquals(9, hits[1].start)
    }

    @Test
    fun caseSensitiveSearchIsLiteral() {
        val text = "Token token TOKEN tokén"
        val hits = TextQuery.of("token", caseSensitive = true).matches(0, text, 10)
        assertEquals(listOf(6), hits.map { it.start })
    }

    @Test
    fun surrogatePairsKeepUtf16Offsets() {
        val text = "😀 HOM27T-P0001"
        val hits = TextQuery.of("hom27t-p0001", false).matches(0, text, 5)
        assertEquals(3, hits.single().start)
        assertEquals(12, hits.single().length)
    }

    @Test
    fun queryIsTrimmedAndEmptyFindsNothing() {
        assertTrue(TextQuery.of("   ", false).isEmpty)
        assertTrue(TextQuery.of("", true).matches(0, "abc", 10).isEmpty())
        assertEquals(1, TextQuery.of("  b ", false).matches(0, "abc", 10).size)
        assertTrue(TextQuery.of("a", false).matches(0, "aaa", 0).isEmpty())
    }

    @Test
    fun matchesAreNonOverlappingAndLimited() {
        val q = TextQuery.of("aa", false)
        assertEquals(listOf(0, 2), q.matches(0, "aaaaa", 10).map { it.start })
        assertEquals(1, q.matches(0, "aaaaa", 1).size)
    }

    @Test
    fun snippetIsOneLineWithContextAndOffsets() {
        val before = "x".repeat(60) + "\n"
        val text = before + "NEEDLE\tafter" + "y".repeat(60)
        val hit = TextQuery.of("needle", false).matches(0, text, 1).single()
        assertEquals(before.length, hit.start)
        assertEquals(TextQuery.CONTEXT, hit.snippetMatchStart)
        assertEquals("NEEDLE", hit.snippet.substring(hit.snippetMatchStart, hit.snippetMatchStart + 6))
        assertFalse(hit.snippet.contains('\n'))
        assertFalse(hit.snippet.contains('\t'))
        assertEquals(TextQuery.CONTEXT * 2 + 6, hit.snippet.length)
    }

    @Test
    fun foldedRangesPointIntoTheOriginal() {
        val f = FoldedText.fold("Ａé")
        assertEquals("ae", f.text)
        assertEquals(0 until 1, f.originalRange(0, 1))
        assertEquals(1 until 2, f.originalRange(1, 2))
        assertEquals("ÄB", FoldedText.identity("ÄB").text)
    }

    @Test
    fun platformLineEndsAreNormalisedWithRawOffsets() {
        val raw = "Title\r\nToken HOM27T-P0001\r\nlast\rend"
        val n = LineEnds.normalise(raw)
        assertEquals("Title\nToken HOM27T-P0001\nlast\nend", n.text)
        val at = n.text.indexOf("HOM27T")
        assertEquals(raw.indexOf("HOM27T"), n.rawIndex(at))
        assertEquals(raw.indexOf("HOM27T") + 12, n.rawIndex(at + 12))
        // A range ending after a CR LF ends after both raw units.
        assertEquals(7, n.rawIndex(6))
        assertEquals(raw.length, n.rawIndex(n.text.length))
        val plain = LineEnds.normalise("abc")
        assertEquals("abc", plain.text)
        assertEquals(2, plain.rawIndex(2))
        assertEquals(3, plain.rawIndex(3))
    }

    // ---- extraction limit ----

    @Test
    fun budgetCutsThePageThatCrossesTheLimit() {
        val b = TextBudget(10)
        assertEquals("abcdef", b.take("abcdef"))
        assertFalse(b.truncated)
        assertEquals("ghij", b.take("ghijkl"))
        assertTrue(b.truncated)
    }

    @Test
    fun budgetWithoutLimitKeepsEverything() {
        val b = TextBudget(-1)
        assertEquals("x".repeat(10_000), b.take("x".repeat(10_000)))
        assertFalse(b.truncated)
    }

    @Test
    fun budgetNeverSplitsASurrogatePair() {
        val b = TextBudget(2)
        assertEquals("a", b.take("a😀"))
        assertTrue(b.truncated)
        val zero = TextBudget(0)
        assertEquals("", zero.take("abc"))
        assertTrue(zero.truncated)
    }

    // ---- outline ----

    private class Node(override val title: String, override val pageIndex: Int, override val key: Any = Any()) : OutlineSource {
        val children = ArrayList<OutlineSource>()

        override fun forEachChild(visit: (OutlineSource) -> Boolean) {
            for (c in children) if (!visit(c)) return
        }
    }

    @Test
    fun outlineIsFlattenedDepthFirst() {
        val root = Node("", -1)
        val a = Node("A", 0)
        val a1 = Node("A.1", 1)
        val a2 = Node("A.2", -1)
        val b = Node("B", 5)
        a.children += listOf(a1, a2)
        root.children += listOf(a, b)
        assertEquals(
            listOf(OutlineEntry("A", 0, 0), OutlineEntry("A.1", 1, 1), OutlineEntry("A.2", -1, 1), OutlineEntry("B", 5, 0)),
            OutlineWalker.flatten(root),
        )
    }

    @Test
    fun outlineCyclesStop() {
        val root = Node("", -1)
        val a = Node("A", 0)
        root.children += a
        a.children += a
        a.children += root
        assertEquals(listOf(OutlineEntry("A", 0, 0)), OutlineWalker.flatten(root))
    }

    @Test
    fun outlineIsBoundedInEntriesAndDepth() {
        val wide = Node("", -1)
        repeat(50) { wide.children += Node("n$it", it) }
        assertEquals(20, OutlineWalker.flatten(wide, maxEntries = 20).size)

        val deep = Node("", -1)
        var cur = deep
        repeat(100) {
            val n = Node("d$it", 0)
            cur.children += n
            cur = n
        }
        val flat = OutlineWalker.flatten(deep)
        assertEquals(OutlineWalker.MAX_DEPTH, flat.size)
        assertEquals(OutlineWalker.MAX_DEPTH - 1, flat.last().depth)
    }

    // ---- errors ----

    @Test
    fun errorsMapToWireCodes() {
        assertEquals("passwordRequired", PdfErrors.from(PdfFailure.locked(), "x").code)
        assertEquals("damaged", PdfErrors.from(PdfFailure.damaged("d"), "x").code)
        assertEquals("ioError", PdfErrors.from(IOException("boom"), "x").code)
        assertEquals("noSpace", PdfErrors.from(IOException("write failed: ENOSPC (No space left on device)"), "x").code)
        assertEquals("internal", PdfErrors.from(IllegalStateException("?"), "x").code)
        assertEquals("internal", PdfErrors.from(OutOfMemoryError(), "x").code)
        val pigeon = PdfPigeonError("notFound", "m", null)
        assertSame(pigeon, PdfErrors.from(pigeon, "x"))
        assertEquals("notSupportedOnDevice", PdfErrors.notSupported("HOM-28A").code)
        assertNull(PdfErrors.notSupported("HOM-28A").details)
    }

    @Test
    fun errorCodeNamesAreTheDartNames() {
        // lib/src/pdf_document.dart PdfErrorCode, in order.
        assertEquals(
            listOf("notSupportedOnDevice", "passwordRequired", "unsupported", "damaged", "cancelled", "noSpace", "notFound", "invalidArgument", "ioError", "internal"),
            PdfErrorCode.values().map { it.name },
        )
    }

    @Test
    fun errorMessagesNeverCarryTheExceptionText() {
        // Rule 30: a path in an exception message must not reach Dart.
        val e = PdfErrors.from(IOException("/storage/emulated/0/Secret Report.pdf: EACCES"), "open")
        assertFalse(e.message!!.contains("Secret"))
        val other = PdfErrors.from(IllegalArgumentException("/data/Secret.pdf"), "open")
        assertFalse(other.message!!.contains("Secret"))
    }
}
