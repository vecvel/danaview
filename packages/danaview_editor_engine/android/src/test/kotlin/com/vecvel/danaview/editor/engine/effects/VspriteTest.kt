// OWNER: AND-09
//
// The `.vsprite` decoder against API-04's fixtures (test_fixtures/sprites/sprites.json: size,
// scale, reveal flag, Adler-32 of the inflated RGBA and glyph bytes, sample pixels), malformed
// files, and the maxTextureSize reduction (ARCH §10.3: sprite textures respect maxTextureSize).

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.JvmFixtures
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.Adler32
import java.util.zip.DeflaterOutputStream

class VspriteTest {
    private val manifest = JSONObject(JvmFixtures.file(FixtureTree.ENGINE_API, "sprites/sprites.json").readText())

    private fun bytes(file: String) = JvmFixtures.file(FixtureTree.ENGINE_API, "sprites/$file").readBytes()

    private fun adler(b: ByteArray): Long = Adler32().apply { update(b) }.value

    @Test
    fun everyFixtureDecodesToItsManifest() {
        val sprites = manifest.getJSONArray("sprites")
        assertEquals(4, sprites.length())
        for (i in 0 until sprites.length()) {
            val s = sprites.getJSONObject(i)
            val file = s.getString("file")
            val img = Vsprite.decode(bytes(file))
            assertEquals(file, s.getInt("width"), img.width)
            assertEquals(file, s.getInt("height"), img.height)
            assertEquals(file, s.getDouble("scale"), img.scale.toDouble(), 1e-6)
            assertEquals(file, s.getBoolean("reveal"), img.hasReveal)
            assertEquals("$file rgba adler", s.getLong("rgbaAdler32"), adler(img.rgba))
            if (img.hasReveal) {
                val le = ByteBuffer.allocate(img.width * img.height * 2).order(ByteOrder.LITTLE_ENDIAN)
                le.asShortBuffer().put(img.glyphs!!)
                assertEquals("$file glyph adler", s.getLong("glyphsAdler32"), adler(le.array()))
            }
            val samples = s.getJSONArray("samples")
            for (j in 0 until samples.length()) {
                val p = samples.getJSONObject(j)
                val x = p.getInt("x")
                val y = p.getInt("y")
                val rgba = p.getJSONArray("rgba")
                for (c in 0 until 4) assertEquals("$file ($x,$y) c$c", rgba.getInt(c), img.rgba[(y * img.width + x) * 4 + c].toInt() and 0xFF)
                if (p.has("glyph")) assertEquals("$file ($x,$y) glyph", p.getInt("glyph"), img.glyphAt(x, y))
            }
        }
    }

    private fun zlib(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        DeflaterOutputStream(out).use { it.write(data) }
        return out.toByteArray()
    }

    private fun header(w: Int, h: Int, flags: Int = 0, version: Int = 1, magic: String = "VSPR", scale: Float = 1f): ByteArray {
        val bb = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(magic.toByteArray(Charsets.US_ASCII)).putShort(version.toShort()).putShort(flags.toShort()).putInt(w).putInt(h).putFloat(scale)
        return bb.array()
    }

    @Test
    fun malformedFilesAreRejected() {
        val rgba = zlib(ByteArray(2 * 2 * 4) { 7 })
        val good = header(2, 2) + rgba
        assertEquals(2, Vsprite.decode(good).width)
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(2, 2, magic = "VSPX") + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(2, 2, version = 2) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(2, 2, flags = 2) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(0, 2) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(2, 2, scale = 0f) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(good + byteArrayOf(0)) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(good.copyOf(good.size - 3)) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(3, 2) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(header(2, 2, flags = 1) + rgba) }
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(ByteArray(10)) }
        val corrupt = good.copyOf()
        corrupt[corrupt.size - 1] = (corrupt[corrupt.size - 1] + 1).toByte()
        assertThrows(IllegalArgumentException::class.java) { Vsprite.decode(corrupt) }
    }

    @Test
    fun fitToMaxTextureSizeAveragesBlocksAndKeepsTheFirstGlyph() {
        val img = Vsprite.decode(bytes("synthetic_reveal_16x8.vsprite"))
        assertSame(img, img.fitTo(16))
        val fit = img.fitTo(4)
        assertEquals(4, fit.width)
        assertEquals(2, fit.height)
        assertEquals(img.scale, fit.scale, 0f)
        for (y in 0 until 2) for (x in 0 until 4) {
            for (c in 0 until 4) {
                var sum = 0
                for (yy in 0 until 4) for (xx in 0 until 4) sum += img.rgba[((y * 4 + yy) * 16 + x * 4 + xx) * 4 + c].toInt() and 0xFF
                assertEquals("($x,$y) c$c", (sum + 8) / 16, fit.rgba[(y * 4 + x) * 4 + c].toInt() and 0xFF)
            }
            var g = Vsprite.BACKGROUND_GLYPH
            for (yy in 0 until 4) for (xx in 0 until 4) g = minOf(g, img.glyphAt(x * 4 + xx, y * 4 + yy))
            assertEquals(g, fit.glyphAt(x, y))
        }
        val text = Vsprite.decode(bytes("text_box_stroke_shadow.vsprite"))
        val small = text.fitTo(128)
        assertTrue(small.width <= 128 && small.height <= 128)
        assertEquals(101, small.width) // ⌈403 / 4⌉
        assertEquals(45, small.height) // ⌈177 / 4⌉
        assertFalse(small.hasReveal)
        assertNull(small.glyphs)
    }
}
