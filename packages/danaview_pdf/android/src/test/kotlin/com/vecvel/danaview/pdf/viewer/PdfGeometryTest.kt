// OWNER: HOM-25
//
// JVM tests of the texture viewer's pure geometry (viewer/PdfGeometry.kt): page space ↔ displayed
// space per rotation, the column layout Dart's PdfTextureLayout uses, viewports and the tile plan.

package com.vecvel.danaview.pdf.viewer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class PdfGeometryTest {
    private val a4 = PageGeometry(595.0, 842.0, 0)
    private val landscape = PageGeometry(842.0, 595.0, 0)
    private val rotated = PageGeometry(612.0, 792.0, 90)

    private fun assertRect(expected: RectD, actual: RectD) {
        val ok = abs(expected.left - actual.left) < 1e-9 && abs(expected.top - actual.top) < 1e-9 &&
            abs(expected.right - actual.right) < 1e-9 && abs(expected.bottom - actual.bottom) < 1e-9
        assertTrue("expected $expected, got $actual", ok)
    }

    @Test
    fun rotationNormalises() {
        assertEquals(0, PageGeometry.normalizeRotation(0))
        assertEquals(90, PageGeometry.normalizeRotation(450))
        assertEquals(270, PageGeometry.normalizeRotation(-90))
        assertEquals(180, PageGeometry.normalizeRotation(-180))
        assertEquals(0, PageGeometry.normalizeRotation(45))
    }

    @Test
    fun displaySizeSwapsOnQuarterTurns() {
        assertEquals(792.0, rotated.displayWidth, 0.0)
        assertEquals(612.0, rotated.displayHeight, 0.0)
        assertEquals(595.0, PageGeometry(595.0, 842.0, 180).displayWidth, 0.0)
        assertEquals(842.0, PageGeometry(595.0, 842.0, 270).displayWidth, 0.0)
    }

    @Test
    fun pageSpaceToDisplayPerRotation() {
        // A 10 x 20 box at x=100, y=700 (bottom-left origin) on a 600 x 800 page.
        val w = 600.0
        val h = 800.0
        // Unrotated, top-left origin: left 100, top 800-720=80, right 110, bottom 100.
        assertRect(RectD(100.0, 80.0, 110.0, 100.0), PageGeometry(w, h, 0).toDisplay(100.0, 700.0, 10.0, 20.0))
        // 90° clockwise: (u, v) → (H - v, u).
        assertRect(RectD(700.0, 100.0, 720.0, 110.0), PageGeometry(w, h, 90).toDisplay(100.0, 700.0, 10.0, 20.0))
        // 180°: (W - u, H - v).
        assertRect(RectD(490.0, 700.0, 500.0, 720.0), PageGeometry(w, h, 180).toDisplay(100.0, 700.0, 10.0, 20.0))
        // 270°: (v, W - u).
        assertRect(RectD(80.0, 490.0, 100.0, 500.0), PageGeometry(w, h, 270).toDisplay(100.0, 700.0, 10.0, 20.0))
    }

    @Test
    fun displayedRectStaysInsideThePage() {
        for (r in listOf(0, 90, 180, 270)) {
            val g = PageGeometry(300.0, 500.0, r)
            val d = g.toDisplay(0.0, 0.0, 300.0, 500.0)
            assertRect(RectD(0.0, 0.0, g.displayWidth, g.displayHeight), d)
        }
    }

    @Test
    fun fromDisplayInvertsToDisplay() {
        for (r in listOf(0, 90, 180, 270)) {
            val g = PageGeometry(600.0, 800.0, r)
            val back = g.fromDisplay(g.toDisplay(100.0, 700.0, 10.0, 20.0))
            assertEquals("x at $r", 100.0, back[0], 1e-9)
            assertEquals("y at $r", 700.0, back[1], 1e-9)
            assertEquals("w at $r", 10.0, back[2], 1e-9)
            assertEquals("h at $r", 20.0, back[3], 1e-9)
        }
        // The platform's box of the token on merge_partner_3p page 3 (A4, /Rotate 90), as API 35 reports it.
        val p = PageGeometry(595.0, 842.0, 90).fromDisplay(RectD(745.0, 90.0, 755.0, 172.0))
        assertEquals(90.0, p[0], 1e-9)
        assertEquals(745.0, p[1], 1e-9)
        assertEquals(82.0, p[2], 1e-9)
        assertEquals(10.0, p[3], 1e-9)
    }

    @Test
    fun reconcileKeepsParsedGeometryWhenTheRendererAgrees() {
        val parsed = PageGeometry(595.28, 841.89, 0)
        assertEquals(parsed, PageGeometry.reconcile(parsed, 595, 841))
        assertEquals(rotated, PageGeometry.reconcile(rotated, 792, 612))
        // Disagreement: the renderer's size wins, unrotated.
        assertEquals(PageGeometry(400.0, 300.0, 0), PageGeometry.reconcile(parsed, 400, 300))
        assertEquals(PageGeometry(400.0, 300.0, 0), PageGeometry.reconcile(null, 400, 300))
        assertEquals(PageGeometry.LETTER, PageGeometry.reconcile(null, 0, 0))
    }

    @Test
    fun layoutMatchesDartPdfTextureLayout() {
        // lib/src/pdf_view.dart: tops accumulate displayHeight + 8, height = last bottom.
        val layout = TextureLayout(listOf(a4, landscape, rotated))
        assertEquals(842.0, layout.width, 0.0)
        assertEquals(0.0, layout.topOf(0), 0.0)
        assertEquals(850.0, layout.topOf(1), 0.0)
        assertEquals(1453.0, layout.topOf(2), 0.0)
        assertEquals(2065.0, layout.height, 0.0)
        assertEquals(3, layout.pageCount)
        assertEquals(0.0, layout.topOf(-5), 0.0)
        assertEquals(1453.0, layout.topOf(99), 0.0)
        assertEquals(0, layout.pageAt(-10.0))
        assertEquals(0, layout.pageAt(849.9))
        assertEquals(1, layout.pageAt(850.0))
        assertEquals(2, layout.pageAt(5000.0))
    }

    @Test
    fun narrowPagesAreCentred() {
        val layout = TextureLayout(listOf(a4, landscape))
        assertRect(RectD(123.5, 0.0, 718.5, 842.0), layout.pageRect(0))
        assertRect(RectD(0.0, 850.0, 842.0, 1445.0), layout.pageRect(1))
    }

    @Test
    fun emptyLayout() {
        val layout = TextureLayout(emptyList())
        assertEquals(0.0, layout.height, 0.0)
        assertEquals(0, layout.pageAt(10.0))
        assertTrue(layout.pagesIn(0.0, 100.0).isEmpty())
        assertEquals(1.0, layout.fitScale(1000), 0.0)
    }

    @Test
    fun pagesInBand() {
        val layout = TextureLayout(List(10) { a4 })
        assertEquals(0..0, layout.pagesIn(0.0, 842.0))
        assertEquals(0..1, layout.pagesIn(0.0, 851.0))
        assertEquals(1..2, layout.pagesIn(1000.0, 1800.0))
        // A band inside a gap still names its neighbour (the plan skips empty intersections).
        assertEquals(0..0, layout.pagesIn(843.0, 849.0))
    }

    @Test
    fun viewportMapsColumnPointsToPixels() {
        val v = Viewport(1080, 2400, 10.0, 100.0, 2.0)
        assertEquals(540.0, v.visibleWidth, 0.0)
        assertEquals(1200.0, v.visibleHeight, 0.0)
        assertRect(RectD(0.0, 0.0, 20.0, 40.0), v.toScreen(RectD(10.0, 100.0, 20.0, 120.0)))
        assertTrue(v.isValid)
        assertFalse(v.copy(scale = 0.0).isValid)
        assertFalse(v.copy(offsetY = Double.NaN).isValid)
    }

    @Test
    fun renderScaleStepsRoundUpWithinNinePercent() {
        var s = 0.1
        while (s < 40) {
            val rs = Tiles.scaleOf(Tiles.stepFor(s))
            assertTrue("render scale $rs below $s", rs >= s * (1 - 1e-9))
            assertTrue("render scale $rs too far above $s", rs <= s * 1.0906)
            s *= 1.037
        }
        assertEquals(1.0, Tiles.scaleOf(Tiles.stepFor(1.0)), 1e-12)
        assertEquals(2.0, Tiles.scaleOf(Tiles.stepFor(2.0)), 1e-12)
    }

    @Test
    fun tilePlanCoversTheVisibleArea() {
        val layout = TextureLayout(List(200) { a4 })
        val fit = layout.fitScale(1440)
        for (zoom in listOf(1.0, 2.5, 8.0)) {
            val v = Viewport(1440, 3120, 50.0 * (zoom - 1), 30_000.0, fit * zoom)
            val step = Tiles.stepFor(v.scale)
            val rs = Tiles.scaleOf(step)
            val plan = Tiles.plan(layout, v.rect, step)
            assertTrue(plan.isNotEmpty())
            assertEquals(plan.size, plan.toSet().size)
            // Every visible point of every page lies in some planned tile.
            val area = v.rect
            for (page in layout.pagesIn(area.top, area.bottom)) {
                val vis = layout.pageRect(page).intersect(area)
                if (vis.isEmpty) continue
                for (fx in listOf(0.001, 0.5, 0.999)) for (fy in listOf(0.001, 0.5, 0.999)) {
                    val x = vis.left + vis.width * fx
                    val y = vis.top + vis.height * fy
                    val covered = plan.any { k ->
                        k.page == page && Tiles.tileRect(layout.pageRect(page), rs, k.col, k.row).let { x >= it.left && x < it.right && y >= it.top && y < it.bottom }
                    }
                    assertTrue("($x, $y) of page $page not covered at zoom $zoom", covered)
                }
            }
            // Nearest the centre first.
            val cx = (area.left + area.right) / 2
            val cy = (area.top + area.bottom) / 2
            val d = plan.map { k ->
                val r = Tiles.tileRect(layout.pageRect(k.page), rs, k.col, k.row)
                val tx = (r.left + r.right) / 2 - cx
                val ty = (r.top + r.bottom) / 2 - cy
                tx * tx + ty * ty
            }
            assertEquals(d.sorted(), d)
        }
    }

    @Test
    fun tilePlanOfAreaOutsideThePagesIsEmpty() {
        val layout = TextureLayout(listOf(a4))
        assertTrue(Tiles.plan(layout, RectD(0.0, 900.0, 595.0, 1000.0), 0).isEmpty())
        assertTrue(Tiles.plan(layout, RectD(0.0, 0.0, 0.0, 0.0), 0).isEmpty())
    }

    @Test
    fun warmUpPdfHasAValidXref() {
        val text = String(PdfWarmUp.tinyPdf(), Charsets.ISO_8859_1)
        assertTrue(text.startsWith("%PDF-1.4"))
        val xrefAt = text.substringAfter("startxref\n").substringBefore("\n").toInt()
        assertTrue(text.startsWith("xref", xrefAt))
        val entries = text.substring(xrefAt).lines().drop(3).take(5)
        entries.forEachIndexed { i, e -> assertTrue("object ${i + 1}", text.startsWith("${i + 1} 0 obj", e.substring(0, 10).toInt())) }
        val stream = text.substringAfter("stream\n").substringBefore("\nendstream")
        assertEquals(text.substringAfter("/Length ").substringBefore(" ").toInt(), stream.length)
    }

    @Test
    fun tileBudgetHoldsAtLeastOneScreen() {
        val v = Viewport(1440, 3120, 0.0, 0.0, 2.0)
        val oneScreen = (3 + 1) * (7 + 1) * Tiles.SIZE * Tiles.SIZE * 4
        assertTrue(PdfTextureView.tileBudget(v) >= oneScreen)
    }
}
