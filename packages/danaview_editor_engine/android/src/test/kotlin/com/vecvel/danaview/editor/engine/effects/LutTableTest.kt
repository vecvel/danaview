// OWNER: AND-09
//
// `.vlut` decoding, float16 conversion and the tiled LUT layout (ARCH §10.2, §11.6 "LUT"):
// every `lut` row of API-03's render_math.json (inline tables and luts/synthetic_17.vlut) is
// reproduced by LutTable.lookupTiled, the CPU mirror of dv_look.glsl's tiled trilinear lookup.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.JvmFixtures
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class LutTableTest {
    private val renderMath = JSONObject(JvmFixtures.file(FixtureTree.ENGINE_API, "vectors/render_math.json").readText())

    private fun table(name: String): LutTable {
        val l = renderMath.getJSONObject("luts").getJSONObject(name)
        return if (l.has("file")) {
            LutTable.decode(JvmFixtures.file(FixtureTree.ENGINE_API, "vectors/" + l.getString("file")).readBytes())
        } else {
            val rgb = l.getJSONArray("rgb")
            LutTable.fromFloats(l.getInt("n"), DoubleArray(rgb.length()) { rgb.getDouble(it) })
        }
    }

    @Test
    fun everyLutRowMatchesTheTiledLookup() {
        val rows = renderMath.getJSONArray("rows")
        var checked = 0
        for (i in 0 until rows.length()) {
            val r = rows.getJSONObject(i)
            if (r.getString("stage") != "lut") continue
            val p = r.getJSONObject("params")
            val lutName = p.getString("lut")
            val lut = table(lutName)
            val intensity = p.getDouble("i")
            val inp = r.getJSONArray("in")
            val out = r.getJSONArray("out")
            val c = DoubleArray(3) { inp.getDouble(it) }
            val l = lut.lookupTiled(c[0], c[1], c[2])
            // Inline tables are float64 in the JSON; the texture holds float16 (≤ 2^-11 relative).
            val tol = if (renderMath.getJSONObject("luts").getJSONObject(lutName).has("file")) 1e-6 else 1e-3
            for (ch in 0 until 3) {
                val got = c[ch] * (1 - intensity) + l[ch] * intensity
                assertEquals("${r.getString("name")} ch$ch", out.getDouble(ch), got, tol)
            }
            assertEquals("alpha unchanged", inp.getDouble(3), out.getDouble(3), 0.0)
            checked++
        }
        assertTrue("lut rows checked: $checked", checked >= 40)
    }

    @Test
    fun synthetic17DecodesAndTiles() {
        val t = table("n17_synthetic_file")
        assertEquals(17, t.size)
        assertEquals(5, t.tilesPerRow)
        assertEquals(85, t.textureWidth)
        assertEquals(68, t.textureHeight)
        // Entry (r, g, b) sits at tile b, texel (r, g) inside it.
        assertEquals(Pair(3 * 17 + 4, 2 * 17 + 5), t.texelOf(4, 5, 13))
        val tiled = t.tiledHalfRgba()
        val (x, y) = t.texelOf(4, 5, 13)
        val o = (y * t.textureWidth + x) * 4
        for (ch in 0 until 3) assertEquals(t.half(4, 5, 13, ch), tiled[o + ch])
        assertEquals(Half.ONE, tiled[o + 3])
        val bytes = t.tiledRgba8()
        assertEquals(LutTable.toByte(t.value(4, 5, 13, 1)), bytes[o + 1].toInt() and 0xFF)
    }

    @Test
    fun largestTableFitsTheDocumentedTexture() {
        assertEquals(9, LutTable.tilesPerRow(65))
        val n = 65
        val t = LutTable.fromFloats(n, DoubleArray(n * n * n * 3) { 0.5 })
        assertEquals(585, t.textureWidth)
        assertEquals(520, t.textureHeight)
        assertEquals(2, LutTable.tilesPerRow(2))
        assertEquals(2, LutTable.tilesPerRow(4))
        assertEquals(3, LutTable.tilesPerRow(5))
    }

    @Test
    fun identityLookupIsExact() {
        val n = 9
        val rgb = DoubleArray(n * n * n * 3)
        var o = 0
        for (b in 0 until n) for (g in 0 until n) for (r in 0 until n) {
            rgb[o++] = r / (n - 1.0); rgb[o++] = g / (n - 1.0); rgb[o++] = b / (n - 1.0)
        }
        val t = LutTable.fromFloats(n, rgb)
        val l = t.lookupTiled(0.3, 0.71, 1.0)
        assertEquals(0.3, l[0], 2e-3)
        assertEquals(0.71, l[1], 2e-3)
        assertEquals(1.0, l[2], 1e-9)
        val clamped = t.lookupTiled(-0.5, 2.0, 0.0)
        assertEquals(0.0, clamped[0], 1e-9)
        assertEquals(1.0, clamped[1], 1e-9)
    }

    @Test
    fun halfConversionsRoundTrip() {
        assertEquals(0x3C00.toShort(), Half.fromFloat(1f))
        assertEquals(0x3800.toShort(), Half.fromFloat(0.5f))
        assertEquals(0xC000.toShort(), Half.fromFloat(-2f))
        assertEquals(0x7BFF.toShort(), Half.fromFloat(65504f))
        assertEquals(0x7BFF.toShort(), Half.fromFloat(1e9f))
        assertEquals(0x0001.toShort(), Half.fromFloat(5.9604645e-8f))
        assertEquals(0x7E00.toShort(), Half.fromFloat(Float.NaN))
        assertEquals(65504f, Half.toFloat(0x7BFF), 0f)
        var finite = 0
        for (bits in 0 until 0x10000) {
            val h = bits.toShort()
            val exp = (bits ushr 10) and 0x1F
            if (exp == 0x1F) continue
            val f = Half.toFloat(h)
            val back = Half.fromFloat(f)
            // ±0 both map to their own sign.
            assertEquals("half 0x${Integer.toHexString(bits)}", h, back)
            finite++
        }
        assertEquals(63488, finite)
        // Round to nearest even between 1 and 1 + 2^-10.
        assertEquals(0x3C00.toShort(), Half.fromFloat(1f + 1f / 2048f))
        assertEquals(0x3C01.toShort(), Half.fromFloat(1f + 1.5f / 2048f))
    }

    private fun vlut(n: Int, version: Int = 1, magic: String = "VLUT", extra: Int = 0): ByteArray {
        val bb = ByteBuffer.allocate(8 + n * n * n * 6 + extra).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(magic.toByteArray(Charsets.US_ASCII)).putShort(version.toShort()).putShort(n.toShort())
        return bb.array()
    }

    @Test
    fun malformedFilesAreRejected() {
        LutTable.decode(vlut(2))
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(vlut(2, magic = "VLUX")) }
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(vlut(2, version = 2)) }
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(vlut(2, extra = 2)) }
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(vlut(66)) }
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(ByteArray(5)) }
        val one = vlut(2).copyOf(8)
        ByteBuffer.wrap(one).order(ByteOrder.LITTLE_ENDIAN).putShort(6, 1)
        assertThrows(IllegalArgumentException::class.java) { LutTable.decode(one) }
    }
}
