// OWNER: AND-09
//
// `.vsprite` v1 (ARCH §10.3, D-06; API-04 writes them): little-endian 'VSPR', u16 version = 1,
// u16 flags (bit0 = hasReveal, other bits 0), u32 width, u32 height, f32 scale (sprite px per
// canvas px); then a zlib stream of width·height·4 bytes (premultiplied RGBA8, gamma-encoded, top
// row first) and, with hasReveal, a second zlib stream of width·height·2 bytes (u16 LE glyph order
// per pixel, 0xFFFF = background). The streams have no length fields: the first is inflated to its
// end and the second starts at the next byte (Inflater.getRemaining()). Both Adler-32 trailers are
// checked by Inflater and nothing may follow the last stream. Decoding and the maxTextureSize
// reduction are pure (JVM-tested against API-04's sprites.json); [SpriteTexture] uploads on the GL
// thread (colour RGBA8 premultiplied, glyphs as LUMINANCE_ALPHA = high byte / low byte, NEAREST).

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlin.math.ceil
import kotlin.math.max

/** A decoded sprite: premultiplied RGBA8 rows (top first) and optional glyph ids. */
class VspriteImage(val width: Int, val height: Int, val scale: Float, val rgba: ByteArray, val glyphs: ShortArray?) {
    init {
        require(width > 0 && height > 0) { "sprite size" }
        require(rgba.size == width * height * 4) { "rgba length" }
        require(glyphs == null || glyphs.size == width * height) { "glyph length" }
    }

    /** Whether the sprite carries a glyph-order map. */
    val hasReveal: Boolean get() = glyphs != null

    /** Glyph id at ([x], [y]) (0xFFFF when there is no map). */
    fun glyphAt(x: Int, y: Int): Int = glyphs?.let { it[y * width + x].toInt() and 0xFFFF } ?: Vsprite.BACKGROUND_GLYPH

    /**
     * This sprite reduced so that neither side exceeds [maxSide] (ARCH §10.3: sprite textures
     * respect maxTextureSize): an integer factor f = ⌈max(w, h) / maxSide⌉, each output texel the
     * average of an f × f block (premultiplied, so averaging is exact) and the smallest glyph id of
     * the block (the block shows as soon as its first glyph is revealed). Returns this when it fits.
     */
    fun fitTo(maxSide: Int): VspriteImage {
        require(maxSide > 0) { "maxSide" }
        if (width <= maxSide && height <= maxSide) return this
        val f = ceil(max(width, height).toDouble() / maxSide).toInt()
        val w = (width + f - 1) / f
        val h = (height + f - 1) / f
        val out = ByteArray(w * h * 4)
        val g = glyphs?.let { ShortArray(w * h) }
        for (y in 0 until h) for (x in 0 until w) {
            val sums = IntArray(4)
            var n = 0
            var minGlyph = Vsprite.BACKGROUND_GLYPH
            for (yy in y * f until minOf(height, (y + 1) * f)) for (xx in x * f until minOf(width, (x + 1) * f)) {
                val o = (yy * width + xx) * 4
                for (c in 0 until 4) sums[c] += rgba[o + c].toInt() and 0xFF
                n++
                if (glyphs != null) minGlyph = minOf(minGlyph, glyphs[yy * width + xx].toInt() and 0xFFFF)
            }
            val o = (y * w + x) * 4
            for (c in 0 until 4) out[o + c] = ((sums[c] + n / 2) / n).toByte()
            if (g != null) g[y * w + x] = minGlyph.toShort()
        }
        return VspriteImage(w, h, scale, out, g)
    }
}

/** The `.vsprite` decoder (file header). */
object Vsprite {
    /** Glyph id of texels outside every glyph. */
    const val BACKGROUND_GLYPH = 0xFFFF

    private const val HEADER = 20
    private const val FLAG_REVEAL = 1
    private const val MAX_SIDE = 16384

    /** Decodes [bytes]; throws IllegalArgumentException on a malformed file. */
    fun decode(bytes: ByteArray): VspriteImage {
        require(bytes.size >= HEADER) { "vsprite: truncated header" }
        require(bytes[0] == 'V'.code.toByte() && bytes[1] == 'S'.code.toByte() && bytes[2] == 'P'.code.toByte() && bytes[3] == 'R'.code.toByte()) { "vsprite: missing 'VSPR' magic" }
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val version = bb.getShort(4).toInt() and 0xFFFF
        require(version == 1) { "vsprite: unsupported version $version" }
        val flags = bb.getShort(6).toInt() and 0xFFFF
        require(flags and FLAG_REVEAL.inv() == 0) { "vsprite: unknown flags $flags" }
        val w = bb.getInt(8).toLong() and 0xFFFFFFFFL
        val h = bb.getInt(12).toLong() and 0xFFFFFFFFL
        require(w in 1..MAX_SIDE && h in 1..MAX_SIDE) { "vsprite: bad size ${w}x$h" }
        val scale = bb.getFloat(16)
        require(scale.isFinite() && scale > 0) { "vsprite: bad scale" }
        val width = w.toInt()
        val height = h.toInt()
        val rgba = ByteArray(width * height * 4)
        var offset = inflate(bytes, HEADER, rgba, "rgba")
        var glyphs: ShortArray? = null
        if (flags and FLAG_REVEAL != 0) {
            val raw = ByteArray(width * height * 2)
            offset = inflate(bytes, offset, raw, "glyphs")
            glyphs = ShortArray(width * height)
            ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(glyphs)
        }
        require(offset == bytes.size) { "vsprite: ${bytes.size - offset} trailing bytes" }
        return VspriteImage(width, height, scale, rgba, glyphs)
    }

    /** Inflates one zlib stream starting at [from] into exactly [out]; returns the next offset. */
    private fun inflate(bytes: ByteArray, from: Int, out: ByteArray, what: String): Int {
        require(from < bytes.size) { "vsprite: missing $what stream" }
        val inf = Inflater()
        try {
            inf.setInput(bytes, from, bytes.size - from)
            var n = 0
            while (n < out.size) {
                val got = inf.inflate(out, n, out.size - n)
                require(got > 0) { "vsprite: $what stream too short" }
                n += got
            }
            // The stream must end exactly here (its Adler-32 trailer is verified by Inflater).
            val probe = ByteArray(1)
            var tries = 0
            while (!inf.finished()) {
                val extra = inf.inflate(probe)
                require(extra == 0) { "vsprite: $what stream too long" }
                require(!inf.needsInput() && ++tries < 8) { "vsprite: $what stream truncated" }
            }
            return bytes.size - inf.remaining
        } catch (e: DataFormatException) {
            throw IllegalArgumentException("vsprite: corrupt $what stream", e)
        } finally {
            inf.end()
        }
    }
}

/** A sprite on the GPU: colour and (with reveal) glyph textures; GL-thread confined. */
class SpriteTexture private constructor(
    val color: Int,
    val glyphs: Int,
    val width: Int,
    val height: Int,
    private val confinement: GlThreadConfinement,
) {
    private var released = false

    /** Whether a glyph map was uploaded. */
    val hasGlyphs: Boolean get() = glyphs != 0

    /** Deletes the textures. */
    fun release() {
        confinement.check()
        if (released) return
        released = true
        GlResources.deleteTexture(color)
        GlResources.deleteTexture(glyphs)
    }

    companion object {
        /**
         * Uploads [image] reduced to [maxTextureSize] (rows flipped to GL order: row 0 = bottom, as
         * every texture of the effects package).
         */
        fun upload(image: VspriteImage, maxTextureSize: Int): SpriteTexture {
            val confinement = GlThreadConfinement()
            val img = image.fitTo(maxTextureSize)
            val w = img.width
            val h = img.height
            val color = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            for (y in h - 1 downTo 0) color.put(img.rgba, y * w * 4, w * 4)
            color.position(0)
            val colorTex = GlResources.createTexture(w, h, pixels = color)
            var glyphTex = 0
            val g = img.glyphs
            if (g != null) {
                val la = ByteBuffer.allocateDirect(w * h * 2).order(ByteOrder.nativeOrder())
                for (y in h - 1 downTo 0) for (x in 0 until w) {
                    val v = g[y * w + x].toInt() and 0xFFFF
                    la.put((v ushr 8).toByte()).put((v and 0xFF).toByte())
                }
                la.position(0)
                glyphTex = try {
                    GlResources.createTexture(w, h, GLES20.GL_LUMINANCE_ALPHA, GLES20.GL_LUMINANCE_ALPHA, GLES20.GL_UNSIGNED_BYTE, la, GLES20.GL_NEAREST)
                } catch (e: RuntimeException) {
                    GlResources.deleteTexture(colorTex)
                    throw e
                }
            }
            return SpriteTexture(colorTex, glyphTex, w, h, confinement)
        }
    }
}
